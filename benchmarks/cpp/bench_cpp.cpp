// C++ peer harness: OS threads + a work-helping pool + a ring channel.
// Not fibers. g++ -O3 -std=c++17 -pthread bench_cpp.cpp [-lws2_32]
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

using SteadyClock = std::chrono::steady_clock;

static void keep(size_t v) {
    std::atomic_signal_fence(std::memory_order_seq_cst);
    volatile size_t sink = v;
    (void)sink;
}

static void print_rate(const char* name, size_t ops, double dt_ns) {
    if (ops == 0) {
        std::printf("%s: 0 ops\n", name);
        return;
    }
    if (dt_ns < 1.0) dt_ns = 1.0;
    const double ns_per = dt_ns / static_cast<double>(ops);
    const double ops_per_ns = static_cast<double>(ops) / dt_ns;
    const double mops = static_cast<double>(ops) / (dt_ns / 1e3);
    std::printf("%s: %zu ops in %.3f ms → %.1f ns/op  (%.6f ops/ns, %.2f Mops/s)\n",
                name, ops, dt_ns / 1e6, ns_per, ops_per_ns, mops);
}

static double elapsed_ns(SteadyClock::time_point t0, SteadyClock::time_point t1) {
    return static_cast<double>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
}

static void print_throughput(const char* name, size_t ops, double dt_ns, const char* unit) {
    if (dt_ns < 1.0) dt_ns = 1.0;
    const double per_s = static_cast<double>(ops) / (dt_ns / 1e9);
    std::printf("%s: %zu %s in %.3f ms → %.0f %s/s\n",
                name, ops, unit, dt_ns / 1e6, per_s, unit);
}

template <typename T>
struct Chan {
    std::mutex mu;
    std::condition_variable cv_space;
    std::condition_variable cv_data;
    std::vector<T> buf;
    size_t cap = 0;
    size_t head = 0;
    size_t tail = 0;
    size_t count = 0;
    bool closed = false;
    bool slot_full = false;
    T slot{};
    size_t recv_waiters = 0;

    explicit Chan(size_t capacity) : cap(capacity) {
        if (cap > 0) buf.resize(cap);
    }

    void send(T v) {
        std::unique_lock<std::mutex> lk(mu);
        if (cap == 0) {
            while (!closed && recv_waiters == 0) cv_space.wait(lk);
            if (closed) return;
            slot = std::move(v);
            slot_full = true;
            cv_data.notify_one();
            while (!closed && slot_full) cv_space.wait(lk);
            return;
        }
        while (!closed && count >= cap) cv_space.wait(lk);
        if (closed) return;
        buf[tail] = std::move(v);
        tail = (tail + 1) % cap;
        ++count;
        cv_data.notify_one();
    }

    bool try_send(T v) {
        std::lock_guard<std::mutex> lk(mu);
        if (closed) return false;
        if (cap == 0) {
            if (recv_waiters == 0 || slot_full) return false;
            slot = std::move(v);
            slot_full = true;
            cv_data.notify_one();
            return true;
        }
        if (count >= cap) return false;
        buf[tail] = std::move(v);
        tail = (tail + 1) % cap;
        ++count;
        cv_data.notify_one();
        return true;
    }

    bool recv(T& out) {
        std::unique_lock<std::mutex> lk(mu);
        if (cap == 0) {
            ++recv_waiters;
            cv_space.notify_one();
            while (!closed && !slot_full) cv_data.wait(lk);
            --recv_waiters;
            if (!slot_full) return false;
            out = std::move(slot);
            slot_full = false;
            cv_space.notify_one();
            return true;
        }
        while (!closed && count == 0) cv_data.wait(lk);
        if (count == 0) return false;
        out = std::move(buf[head]);
        head = (head + 1) % cap;
        --count;
        cv_space.notify_one();
        return true;
    }

    bool try_recv(T& out) {
        std::lock_guard<std::mutex> lk(mu);
        if (cap == 0) {
            if (!slot_full) return false;
            out = std::move(slot);
            slot_full = false;
            cv_space.notify_one();
            return true;
        }
        if (count == 0) return false;
        out = std::move(buf[head]);
        head = (head + 1) % cap;
        --count;
        cv_space.notify_one();
        return true;
    }

    void close() {
        std::lock_guard<std::mutex> lk(mu);
        closed = true;
        cv_space.notify_all();
        cv_data.notify_all();
    }
};

struct TaskPool {
    std::mutex mu;
    std::condition_variable cv;
    std::deque<std::function<void()>> q;
    std::vector<std::thread> workers;
    bool stop = false;

    explicit TaskPool(unsigned n = 0) {
        if (n == 0) n = std::max(2u, std::thread::hardware_concurrency());
        workers.reserve(n);
        for (unsigned i = 0; i < n; ++i) {
            workers.emplace_back([this] { loop(); });
        }
    }

    TaskPool(const TaskPool&) = delete;
    TaskPool& operator=(const TaskPool&) = delete;

    ~TaskPool() { shutdown(); }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lk(mu);
            if (stop) return;
            stop = true;
        }
        cv.notify_all();
        for (auto& t : workers) {
            if (t.joinable()) t.join();
        }
        workers.clear();
    }

    bool try_run_one() {
        std::function<void()> job;
        {
            std::unique_lock<std::mutex> lk(mu);
            if (q.empty()) return false;
            job = std::move(q.front());
            q.pop_front();
        }
        job();
        return true;
    }

    template <class F>
    auto submit(F f) -> std::future<decltype(f())> {
        using R = decltype(f());
        auto task = std::make_shared<std::packaged_task<R()>>(std::move(f));
        auto fut = task->get_future();
        {
            std::lock_guard<std::mutex> lk(mu);
            q.emplace_back([task] { (*task)(); });
        }
        cv.notify_one();
        return fut;
    }

    template <class T>
    T wait(std::future<T>& fut) {
        for (;;) {
            if (fut.wait_for(std::chrono::nanoseconds(0)) == std::future_status::ready) {
                return fut.get();
            }
            if (!try_run_one()) {
                fut.wait();
                return fut.get();
            }
        }
    }

    void wait_void(std::future<void>& fut) {
        for (;;) {
            if (fut.wait_for(std::chrono::nanoseconds(0)) == std::future_status::ready) {
                fut.get();
                return;
            }
            if (!try_run_one()) {
                fut.wait();
                fut.get();
                return;
            }
        }
    }

private:
    void loop() {
        for (;;) {
            std::function<void()> job;
            {
                std::unique_lock<std::mutex> lk(mu);
                cv.wait(lk, [&] { return stop || !q.empty(); });
                if (stop && q.empty()) return;
                job = std::move(q.front());
                q.pop_front();
            }
            job();
        }
    }
};

#ifdef _WIN32
using Sock = SOCKET;
static const Sock kInvalid = INVALID_SOCKET;
static void sock_close(Sock s) { closesocket(s); }
#else
using Sock = int;
static const Sock kInvalid = -1;
static void sock_close(Sock s) { ::close(s); }
#endif

static void sock_nodelay(Sock s) {
    const int yes = 1;
#ifdef _WIN32
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&yes), sizeof(yes));
#else
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
#endif
}

static void sock_reuse(Sock s) {
    const int yes = 1;
#ifdef _WIN32
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof(yes));
#else
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#endif
}

static void sock_rcv_timeout_ms(Sock s, int ms) {
#ifdef _WIN32
    DWORD v = static_cast<DWORD>(ms);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&v), sizeof(v));
#else
    timeval tv{};
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
}

#ifdef _WIN32
struct Winsock {
    Winsock() { WSAStartup(MAKEWORD(2, 2), &data); }
    ~Winsock() { WSACleanup(); }
    WSADATA data{};
};
static Winsock g_winsock;
#endif

static void bench_ctx_switch_bounce() {
    const size_t n = 200000;
    std::mutex mu;
    std::condition_variable cv;
    bool turn_a = true;
    size_t remain = n;
    const auto t0 = SteadyClock::now();
    std::thread a([&] {
        std::unique_lock<std::mutex> lk(mu);
        while (remain > 0) {
            cv.wait(lk, [&] { return turn_a; });
            --remain;
            turn_a = false;
            cv.notify_one();
        }
    });
    std::thread b([&] {
        std::unique_lock<std::mutex> lk(mu);
        while (true) {
            cv.wait(lk, [&] { return !turn_a || remain == 0; });
            if (remain == 0 && turn_a) break;
            turn_a = true;
            cv.notify_one();
            if (remain == 0) break;
        }
    });
    a.join();
    b.join();
    print_rate("ctx_switch_bounce", n * 2, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_leaf_spawn(TaskPool& pool) {
    const size_t n = 50000;
    const auto t0 = SteadyClock::now();
    std::vector<std::future<void>> fs;
    fs.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        fs.push_back(pool.submit([] {}));
    }
    for (auto& f : fs) pool.wait_void(f);
    print_rate("leaf_spawn_batch", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_yield_pingpong() {
    const size_t n = 200000;
    std::atomic<int64_t> remain{static_cast<int64_t>(n)};
    const auto t0 = SteadyClock::now();
    std::thread a([&] {
        while (remain.fetch_sub(1, std::memory_order_relaxed) > 0) std::this_thread::yield();
    });
    std::thread b([&] {
        while (remain.fetch_sub(1, std::memory_order_relaxed) > 0) std::this_thread::yield();
    });
    a.join();
    b.join();
    print_rate("yield_pingpong", n * 2, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_yield_single() {
    const size_t n = 500000;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::this_thread::yield();
    print_rate("yield_single", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_yield_ws4() {
    const size_t workers = 4, n = 20000;
    std::vector<std::thread> ts;
    const auto t0 = SteadyClock::now();
    for (size_t w = 0; w < workers; ++w) {
        ts.emplace_back([n] {
            for (size_t i = 0; i < n; ++i) std::this_thread::yield();
        });
    }
    for (auto& t : ts) t.join();
    print_rate("yield_ws_4w", n * workers, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_spawn_join() {
    const size_t n = 2000;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::thread([] {}).join();
    print_rate("spawn_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_spawn_result_join() {
    const size_t n = 2000;
    const auto t0 = SteadyClock::now();
    size_t acc = 0;
    for (size_t i = 0; i < n; ++i) {
        size_t result = 0;
        const size_t iv = i;
        std::thread th([&result, iv] { result = iv + 1; });
        th.join();
        acc += result;
    }
    keep(acc);
    print_rate("spawn_result_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_nursery_join(TaskPool& pool) {
    const size_t n = 2000;
    const auto t0 = SteadyClock::now();
    std::vector<std::future<void>> fs;
    fs.reserve(n);
    for (size_t i = 0; i < n; ++i) fs.push_back(pool.submit([] {}));
    for (auto& f : fs) pool.wait_void(f);
    print_rate("nursery_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_priority_dispatch() {
    const size_t n = 2000;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::thread([] {}).join();
    print_rate("priority_dispatch", n, elapsed_ns(t0, SteadyClock::now()));
}

static size_t skynet(TaskPool& pool, size_t num, size_t size) {
    if (size == 1) return num;
    const size_t div = 10;
    const size_t next = size / div;
    std::future<size_t> fs[10];
    for (size_t i = 0; i < div; ++i) {
        const size_t child = num + i * next;
        fs[i] = pool.submit([&pool, child, next] { return skynet(pool, child, next); });
    }
    size_t sum = 0;
    for (size_t i = 0; i < div; ++i) sum += pool.wait(fs[i]);
    return sum;
}

static void bench_skynet(TaskPool& pool) {
    const size_t size = 10000;
    const auto t0 = SteadyClock::now();
    keep(skynet(pool, 0, size));
    const size_t total_spawns = size + size / 10 + size / 100 + size / 1000 + size / 10000;
    print_rate("skynet_join_10k", total_spawns, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_n_tasks(TaskPool& pool) {
    const size_t counts[] = {1000, 10000, 50000};
    const size_t rounds = 20;
    for (size_t n : counts) {
        const auto t0 = SteadyClock::now();
        std::vector<std::future<void>> fs;
        fs.reserve(n);
        for (size_t i = 0; i < n; ++i) {
            fs.push_back(pool.submit([rounds] {
                for (size_t r = 0; r < rounds; ++r) std::this_thread::yield();
            }));
        }
        for (auto& f : fs) pool.wait_void(f);
        char name[64];
        std::snprintf(name, sizeof(name), "n_tasks_%zu", n);
        print_rate(name, n * rounds, elapsed_ns(t0, SteadyClock::now()));
    }
}

static void bench_chan_pipeline() {
    const size_t n = 200000;
    Chan<size_t> ch(256);
    const auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) ch.send(i);
        ch.close();
    });
    size_t v = 0;
    while (ch.recv(v)) {
    }
    prod.join();
    print_rate("chan_pipeline_buf256", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_rendezvous() {
    const size_t n = 100000;
    Chan<size_t> ch(0);
    const auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) ch.send(i);
        ch.close();
    });
    size_t v = 0;
    while (ch.recv(v)) {
    }
    prod.join();
    print_rate("chan_rendezvous", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_mpmc() {
    const size_t producers = 4, consumers = 4, per = 25000;
    const size_t total = producers * per;
    Chan<size_t> ch(1024);
    std::atomic<size_t> done{0};
    const auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(producers + consumers);
    for (size_t p = 0; p < producers; ++p) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) ch.send(i);
            if (done.fetch_add(1, std::memory_order_acq_rel) + 1 == producers) ch.close();
        });
    }
    for (size_t c = 0; c < consumers; ++c) {
        ts.emplace_back([&] {
            size_t v = 0;
            while (ch.recv(v)) {
            }
        });
    }
    for (auto& t : ts) t.join();
    print_rate("chan_mpmc_4x4", total, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_try_uncontended() {
    const size_t n = 500000;
    Chan<size_t> ch(1);
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        (void)ch.try_send(i);
        size_t v = 0;
        (void)ch.try_recv(v);
    }
    print_rate("chan_try_uncontended", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_create() {
    const size_t n = 50000;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        Chan<size_t> ch(8);
        keep(ch.cap);
    }
    print_rate("chan_create_buf8", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_closed_drain() {
    const size_t n = 100000;
    Chan<size_t> ch(n);
    for (size_t i = 0; i < n; ++i) ch.send(i);
    ch.close();
    const auto t0 = SteadyClock::now();
    size_t v = 0;
    while (ch.recv(v)) {
    }
    print_rate("chan_closed_drain", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_prodcons_work() {
    const size_t n = 50000, work = 100;
    Chan<size_t> ch(64);
    auto spin = [] {
        size_t foo = 1;
        for (size_t i = 0; i < work; ++i) {
            foo = foo * 1664525u + 1013904223u;
        }
        keep(foo);
    };
    const auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) {
            spin();
            ch.send(i);
        }
        ch.close();
    });
    size_t v = 0;
    while (ch.recv(v)) spin();
    prod.join();
    print_rate("chan_prodcons_work", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_popular() {
    const size_t waiters = 64, msgs = 1000;
    Chan<size_t> ch(0);
    const auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(waiters);
    for (size_t w = 0; w < waiters; ++w) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < msgs; ++i) {
                size_t v = 0;
                (void)ch.recv(v);
            }
        });
    }
    std::thread feeder([&] {
        for (size_t i = 0; i < waiters * msgs; ++i) ch.send(i);
        ch.close();
    });
    for (auto& t : ts) t.join();
    feeder.join();
    print_rate("chan_popular_256", waiters * msgs, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_sem() {
    const size_t n = 100000;
    Chan<uint8_t> ch(1);
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        ch.send(0);
        uint8_t v = 0;
        (void)ch.recv(v);
    }
    print_rate("chan_sem", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_actor_mailbox() {
    const size_t n = 50000;
    Chan<uint64_t> ch(256);
    uint64_t sum = 0;
    const auto t0 = SteadyClock::now();
    std::thread actor([&] {
        uint64_t v = 0;
        while (ch.recv(v)) sum += v;
    });
    for (uint64_t i = 0; i < n; ++i) ch.send(i);
    ch.close();
    actor.join();
    keep(static_cast<size_t>(sum));
    print_rate("actor_mailbox", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_fanin() {
    const size_t n = 50000;
    Chan<size_t> a(64), b(64);
    const auto t0 = SteadyClock::now();
    std::thread pa([&] {
        for (size_t i = 0; i < n / 2; ++i) a.send(i);
    });
    std::thread pb([&] {
        for (size_t i = 0; i < n - n / 2; ++i) b.send(i);
    });
    size_t got = 0;
    while (got < n) {
        size_t v = 0;
        if (a.try_recv(v) || b.try_recv(v))
            ++got;
        else
            std::this_thread::yield();
    }
    pa.join();
    pb.join();
    print_rate("select_fanin_2", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_uncontended() {
    const size_t n = 100000;
    Chan<size_t> a(1), b(1);
    a.send(0);
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        size_t v = 0;
        if (a.try_recv(v))
            b.send(0);
        else if (b.try_recv(v))
            a.send(0);
    }
    print_rate("select_uncontended", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_nonblock() {
    const size_t n = 200000;
    Chan<size_t> a(0), b(0);
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        size_t v = 0;
        (void)a.try_recv(v);
        (void)b.try_recv(v);
    }
    print_rate("select_nonblock", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_sync_contended() {
    const size_t n = 30000;
    Chan<size_t> a(32), b(32), c(32);
    const auto t0 = SteadyClock::now();
    std::thread fa([&] {
        for (size_t i = 0; i < n / 3; ++i) a.send(i);
    });
    std::thread fb([&] {
        for (size_t i = 0; i < n / 3; ++i) b.send(i);
    });
    std::thread fc([&] {
        for (size_t i = 0; i < n - 2 * (n / 3); ++i) c.send(i);
    });
    size_t got = 0;
    while (got < n) {
        size_t v = 0;
        if (a.try_recv(v) || b.try_recv(v) || c.try_recv(v))
            ++got;
        else
            std::this_thread::yield();
    }
    fa.join();
    fb.join();
    fc.join();
    print_rate("select_sync_contended", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_mutex_uncontended() {
    const size_t n = 200000;
    std::mutex mu;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        mu.lock();
        mu.unlock();
    }
    print_rate("mutex_uncontended", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_mutex_contended() {
    const size_t workers = 4, per = 25000;
    std::mutex mu;
    size_t counter = 0;
    const auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    for (size_t w = 0; w < workers; ++w) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) {
                std::lock_guard<std::mutex> lk(mu);
                ++counter;
            }
        });
    }
    for (auto& t : ts) t.join();
    keep(counter);
    print_rate("mutex_contended_4", workers * per, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_sem_handoff() {
    const size_t n = 50000;
    std::mutex mu;
    std::condition_variable cv;
    size_t permits = 0;
    const auto t0 = SteadyClock::now();
    std::thread cons([&] {
        for (size_t i = 0; i < n; ++i) {
            std::unique_lock<std::mutex> lk(mu);
            cv.wait(lk, [&] { return permits > 0; });
            --permits;
        }
    });
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) {
            {
                std::lock_guard<std::mutex> lk(mu);
                ++permits;
            }
            cv.notify_one();
        }
    });
    cons.join();
    prod.join();
    print_rate("sem_handoff", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_rwlock_shared() {
    std::shared_mutex mu;
    size_t counter = 0;
    const size_t readers = 4, per = 50000;
    const auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    for (size_t r = 0; r < readers; ++r) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) {
                std::shared_lock<std::shared_mutex> lk(mu);
                keep(counter);
            }
        });
    }
    for (auto& t : ts) t.join();
    print_rate("rwlock_shared_4", readers * per, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_rwlock_exclusive() {
    std::shared_mutex mu;
    size_t counter = 0;
    const size_t n = 100000;
    const auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        std::unique_lock<std::shared_mutex> lk(mu);
        ++counter;
    }
    keep(counter);
    print_rate("rwlock_exclusive", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_timer_sleep_batch(TaskPool& pool) {
    const size_t n = 2000;
    const auto t0 = SteadyClock::now();
    std::vector<std::future<void>> fs;
    fs.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        fs.push_back(pool.submit([] {
            std::this_thread::sleep_for(std::chrono::nanoseconds(50));
        }));
    }
    for (auto& f : fs) pool.wait_void(f);
    print_rate("timer_sleep_batch", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_many_timers(TaskPool& pool) {
    const size_t n = 100000;
    const auto t0 = SteadyClock::now();
    std::vector<std::future<void>> fs;
    fs.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        fs.push_back(pool.submit([i] {
            std::this_thread::sleep_for(std::chrono::nanoseconds(1 + i % 1000));
        }));
    }
    for (auto& f : fs) pool.wait_void(f);
    print_rate("timer_many_100k_dispatch", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_tcp_pingpong() {
    const size_t rounds = 20000;
    Sock ln = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ln == kInvalid) {
        std::printf("tcp_pingpong: skip (socket)\n");
        return;
    }
    sock_reuse(ln);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(ln, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(ln, 1) != 0) {
        std::printf("tcp_pingpong: skip (bind/listen)\n");
        sock_close(ln);
        return;
    }
#ifdef _WIN32
    int alen = sizeof(addr);
#else
    socklen_t alen = sizeof(addr);
#endif
    getsockname(ln, reinterpret_cast<sockaddr*>(&addr), &alen);

    std::thread srv([&] {
        Sock peer = accept(ln, nullptr, nullptr);
        if (peer == kInvalid) return;
        sock_nodelay(peer);
        char buf[64];
        for (;;) {
#ifdef _WIN32
            const int n = recv(peer, buf, sizeof(buf), 0);
#else
            const ssize_t n = recv(peer, buf, sizeof(buf), 0);
#endif
            if (n <= 0) break;
            if (send(peer, buf, static_cast<int>(n), 0) < 0) break;
        }
        sock_close(peer);
    });

    Sock cli = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (cli == kInvalid || connect(cli, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        std::printf("tcp_pingpong: skip (connect)\n");
        if (cli != kInvalid) sock_close(cli);
        sock_close(ln);
        srv.join();
        return;
    }
    sock_nodelay(cli);
    const char msg[] = "PING\n";
    char buf[5];
    const auto t0 = SteadyClock::now();
    size_t completed = 0;
    for (size_t i = 0; i < rounds; ++i) {
        if (send(cli, msg, 5, 0) != 5) break;
        int got = 0;
        while (got < 5) {
#ifdef _WIN32
            const int n = recv(cli, buf + got, 5 - got, 0);
#else
            const ssize_t n = recv(cli, buf + got, 5 - got, 0);
#endif
            if (n <= 0) {
                got = -1;
                break;
            }
            got += static_cast<int>(n);
        }
        if (got < 0) break;
        ++completed;
    }
    const auto t1 = SteadyClock::now();
    sock_close(cli);
    sock_close(ln);
    srv.join();
    if (completed == 0) {
        std::printf("tcp_pingpong: failed (0 roundtrips)\n");
        return;
    }
    print_throughput("tcp_pingpong", completed, elapsed_ns(t0, t1), "roundtrips");
    print_rate("tcp_pingpong_latency", completed, elapsed_ns(t0, t1));
}

static void bench_udp_ping() {
    const size_t rounds = 10000;
    Sock srv = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    Sock cli = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (srv == kInvalid || cli == kInvalid) {
        std::printf("udp_ping: skip (socket)\n");
        if (srv != kInvalid) sock_close(srv);
        if (cli != kInvalid) sock_close(cli);
        return;
    }
    sockaddr_in saddr{};
    saddr.sin_family = AF_INET;
    saddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    saddr.sin_port = 0;
    if (bind(srv, reinterpret_cast<sockaddr*>(&saddr), sizeof(saddr)) != 0) {
        std::printf("udp_ping: skip (bind)\n");
        sock_close(srv);
        sock_close(cli);
        return;
    }
#ifdef _WIN32
    int alen = sizeof(saddr);
#else
    socklen_t alen = sizeof(saddr);
#endif
    getsockname(srv, reinterpret_cast<sockaddr*>(&saddr), &alen);
    sock_rcv_timeout_ms(srv, 250);

    std::atomic<size_t> got{0};
    std::thread reader([&] {
        char buf[32];
        while (got.load(std::memory_order_relaxed) < rounds) {
            sockaddr_in from{};
#ifdef _WIN32
            int flen = sizeof(from);
#else
            socklen_t flen = sizeof(from);
#endif
            if (recvfrom(srv, buf, sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &flen) < 0) break;
            got.fetch_add(1, std::memory_order_relaxed);
        }
    });

    const char payload[] = "PING";
    const auto t0 = SteadyClock::now();
    size_t completed = 0;
    for (size_t i = 0; i < rounds; ++i) {
        if (sendto(cli, payload, 4, 0, reinterpret_cast<sockaddr*>(&saddr), sizeof(saddr)) < 0) break;
        ++completed;
    }
    reader.join();
    const auto t1 = SteadyClock::now();
    sock_close(srv);
    sock_close(cli);
    if (completed == 0) {
        std::printf("udp_ping: failed (0 packets)\n");
        return;
    }
    print_throughput("udp_ping", completed, elapsed_ns(t0, t1), "pkts");
    print_rate("udp_ping_latency", completed, elapsed_ns(t0, t1));
}

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    TaskPool pool;
    std::printf("cpp bench  thread-pool+%u workers  ring+rendezvous chan  c++17\n",
                static_cast<unsigned>(pool.workers.size()));
    std::printf("--- fiber / spawn (OS threads / pool) ---\n");
    bench_ctx_switch_bounce();
    bench_yield_pingpong();
    bench_yield_single();
    bench_yield_ws4();
    bench_leaf_spawn(pool);
    bench_spawn_join();
    bench_spawn_result_join();
    bench_nursery_join(pool);
    bench_priority_dispatch();
    bench_skynet(pool);
    bench_n_tasks(pool);

    std::printf("--- channel / actor ---\n");
    bench_chan_pipeline();
    bench_chan_rendezvous();
    bench_chan_mpmc();
    bench_chan_try_uncontended();
    bench_chan_create();
    bench_chan_closed_drain();
    bench_chan_prodcons_work();
    bench_chan_popular();
    bench_chan_sem();
    bench_actor_mailbox();

    std::printf("--- select ---\n");
    bench_select_fanin();
    bench_select_uncontended();
    bench_select_nonblock();
    bench_select_sync_contended();

    std::printf("--- sync ---\n");
    bench_mutex_uncontended();
    bench_mutex_contended();
    bench_sem_handoff();
    bench_rwlock_shared();
    bench_rwlock_exclusive();

    std::printf("--- timers ---\n");
    bench_timer_sleep_batch(pool);
    bench_many_timers(pool);

    std::printf("--- io ---\n");
    bench_tcp_pingpong();
    bench_udp_ping();

    std::printf("---\ndone\n");
    return 0;
}
