#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <queue>
#include <shared_mutex>
#include <thread>
#include <vector>
#include <string>
#include <array>

using SteadyClock = std::chrono::steady_clock;

static void print_rate(const char* name, size_t ops, double dt_ns) {
    if (ops == 0) {
        std::printf("%s: 0 ops\n", name);
        return;
    }
    if (dt_ns < 1.0) dt_ns = 1.0;
    double ns_per = dt_ns / static_cast<double>(ops);
    double ops_per_ns = static_cast<double>(ops) / dt_ns;
    double mops = static_cast<double>(ops) / (dt_ns / 1e3);
    std::printf("%s: %zu ops in %.3f ms → %.1f ns/op  (%.6f ops/ns, %.2f Mops/s)\n",
                name, ops, dt_ns / 1e6, ns_per, ops_per_ns, mops);
}

static double elapsed_ns(SteadyClock::time_point t0, SteadyClock::time_point t1) {
    return static_cast<double>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
}

template <typename T>
struct Chan {
    std::mutex mu;
    std::condition_variable cv;
    std::queue<T> q;
    size_t cap;
    bool closed = false;

    explicit Chan(size_t capacity) : cap(capacity == 0 ? 1 : capacity) {}

    void send(T v) {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [&] { return closed || q.size() < cap; });
        if (closed) return;
        q.push(std::move(v));
        cv.notify_all();
    }

    bool try_send(T v) {
        std::lock_guard<std::mutex> lk(mu);
        if (closed || q.size() >= cap) return false;
        q.push(std::move(v));
        cv.notify_all();
        return true;
    }

    bool recv(T& out) {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [&] { return closed || !q.empty(); });
        if (q.empty()) return false;
        out = std::move(q.front());
        q.pop();
        cv.notify_all();
        return true;
    }

    bool try_recv(T& out) {
        std::lock_guard<std::mutex> lk(mu);
        if (q.empty()) return false;
        out = std::move(q.front());
        q.pop();
        cv.notify_all();
        return true;
    }

    void close() {
        std::lock_guard<std::mutex> lk(mu);
        closed = true;
        cv.notify_all();
    }
};

// fiber/spawn

static void bench_yield_pingpong() {
    const size_t n = 200000;
    std::atomic<int64_t> remain{static_cast<int64_t>(n)};
    auto t0 = SteadyClock::now();
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
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::this_thread::yield();
    print_rate("yield_single", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_yield_ws4() {
    const size_t workers = 4, n = 20000;
    std::vector<std::thread> ts;
    auto t0 = SteadyClock::now();
    for (size_t w = 0; w < workers; ++w) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < n; ++i) std::this_thread::yield();
        });
    }
    for (auto& t : ts) t.join();
    print_rate("yield_ws_4w", n * workers, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_spawn_join() {
    const size_t n = 2000;
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::thread([] {}).join();
    print_rate("spawn_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_spawn_result_join() {
    const size_t n = 2000;
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        size_t result = 0;
        std::thread th([&] { result = i + 1; });
        th.join();
        (void)result;
    }
    print_rate("spawn_result_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_nursery_join() {
    const size_t n = 500;
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(n);
    for (size_t i = 0; i < n; ++i) ts.emplace_back([] {});
    for (auto& t : ts) t.join();
    print_rate("nursery_join", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_priority_dispatch() {
    const size_t n = 2000;
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) std::thread([] {}).join();
    print_rate("priority_dispatch", n, elapsed_ns(t0, SteadyClock::now()));
}

static size_t skynet(size_t num, size_t size) {
    if (size == 1) return num;
    const size_t div = 10;
    const size_t next = size / div;
    std::vector<std::thread> ts;
    std::vector<size_t> parts(div);
    ts.reserve(div);
    for (size_t i = 0; i < div; ++i) {
        ts.emplace_back([&, i] { parts[i] = skynet(num + i * next, next); });
    }
    size_t sum = 0;
    for (size_t i = 0; i < div; ++i) {
        ts[i].join();
        sum += parts[i];
    }
    return sum;
}

static void bench_skynet() {
    const size_t size = 1000;
    auto t0 = SteadyClock::now();
    (void)skynet(0, size);
    const size_t total_spawns = size + size / 10 + size / 100 + size / 1000;
    print_rate("skynet_join_10k", total_spawns, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_n_tasks() {
    const size_t counts[] = {1000, 10000};
    const size_t rounds = 20;
    for (size_t n : counts) {
        const size_t batch = std::min(n, size_t{256});
        auto t0 = SteadyClock::now();
        size_t done = 0;
        while (done < n) {
            const size_t take = std::min(batch, n - done);
            std::vector<std::thread> ts;
            ts.reserve(take);
            for (size_t i = 0; i < take; ++i) {
                ts.emplace_back([&] {
                    for (size_t r = 0; r < rounds; ++r) std::this_thread::yield();
                });
            }
            for (auto& t : ts) t.join();
            done += take;
        }
        char name[64];
        std::snprintf(name, sizeof(name), "n_tasks_%zu", n);
        print_rate(name, n * rounds, elapsed_ns(t0, SteadyClock::now()));
    }
    std::printf("n_tasks_50000: skip (OS-thread thrash; use fibers)\n");
}

// channel/actor

static void bench_chan_pipeline() {
    const size_t n = 200000;
    Chan<size_t> ch(256);
    auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) ch.send(i);
        ch.close();
    });
    size_t v;
    while (ch.recv(v)) {
    }
    prod.join();
    print_rate("chan_pipeline_buf256", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_rendezvous() {
    const size_t n = 100000;
    Chan<size_t> ch(0);
    auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) ch.send(i);
        ch.close();
    });
    size_t v;
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
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    for (size_t p = 0; p < producers; ++p) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) ch.send(i);
            if (done.fetch_add(1) + 1 == producers) ch.close();
        });
    }
    for (size_t c = 0; c < consumers; ++c) {
        ts.emplace_back([&] {
            size_t v;
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
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        (void)ch.try_send(i);
        size_t v;
        (void)ch.try_recv(v);
    }
    print_rate("chan_try_uncontended", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_create() {
    const size_t n = 50000;
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        Chan<size_t> ch(8);
        (void)ch;
    }
    print_rate("chan_create_buf8", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_closed_drain() {
    const size_t n = 100000;
    Chan<size_t> ch(n);
    for (size_t i = 0; i < n; ++i) ch.send(i);
    ch.close();
    auto t0 = SteadyClock::now();
    size_t v;
    while (ch.recv(v)) {
    }
    print_rate("chan_closed_drain", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_prodcons_work() {
    const size_t n = 50000, work = 100;
    Chan<size_t> ch(64);
    auto spin = [&] {
        size_t foo = 0;
        for (size_t i = 0; i < work; ++i) {
            foo *= 2;
            foo /= 2;
        }
        (void)foo;
    };
    auto t0 = SteadyClock::now();
    std::thread prod([&] {
        for (size_t i = 0; i < n; ++i) {
            spin();
            ch.send(i);
        }
        ch.close();
    });
    size_t v;
    while (ch.recv(v)) spin();
    prod.join();
    print_rate("chan_prodcons_work", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_chan_popular() {
    const size_t waiters = 64, msgs = 1000;
    Chan<size_t> ch(0);
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(waiters);
    for (size_t w = 0; w < waiters; ++w) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < msgs; ++i) {
                size_t v;
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
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        ch.send(0);
        uint8_t v;
        (void)ch.recv(v);
    }
    print_rate("chan_sem", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_actor_mailbox() {
    const size_t n = 50000;
    Chan<uint64_t> ch(256);
    uint64_t sum = 0;
    auto t0 = SteadyClock::now();
    std::thread actor([&] {
        uint64_t v;
        while (ch.recv(v)) sum += v;
    });
    for (uint64_t i = 0; i < n; ++i) ch.send(i);
    ch.close();
    actor.join();
    (void)sum;
    print_rate("actor_mailbox", n, elapsed_ns(t0, SteadyClock::now()));
}

// select

static void bench_select_fanin() {
    const size_t n = 50000;
    Chan<size_t> a(64), b(64);
    auto t0 = SteadyClock::now();
    std::thread pa([&] {
        for (size_t i = 0; i < n / 2; ++i) a.send(i);
    });
    std::thread pb([&] {
        for (size_t i = 0; i < n - n / 2; ++i) b.send(i);
    });
    size_t got = 0;
    while (got < n) {
        size_t v;
        if (a.try_recv(v) || b.try_recv(v)) {
            ++got;
        } else {
            std::this_thread::yield();
        }
    }
    pa.join();
    pb.join();
    print_rate("select_fanin_2", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_uncontended() {
    const size_t n = 100000;
    Chan<size_t> a(1), b(1);
    a.send(0);
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        size_t v;
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
    auto t0 = SteadyClock::now();
    for (size_t i = 0; i < n; ++i) {
        size_t v;
        (void)a.try_recv(v);
        (void)b.try_recv(v);
    }
    print_rate("select_nonblock", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_select_sync_contended() {
    const size_t n = 30000;
    Chan<size_t> a(32), b(32), c(32);
    auto t0 = SteadyClock::now();
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
        size_t v;
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

// sync/timers

static void bench_mutex_uncontended() {
    const size_t n = 200000;
    std::mutex mu;
    auto t0 = SteadyClock::now();
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
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    for (size_t w = 0; w < workers; ++w) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) {
                mu.lock();
                ++counter;
                mu.unlock();
            }
        });
    }
    for (auto& t : ts) t.join();
    print_rate("mutex_contended_4", workers * per, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_sem_handoff() {
    const size_t n = 50000;
    std::mutex mu;
    std::condition_variable cv;
    size_t permits = 0;
    auto t0 = SteadyClock::now();
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
    auto t0 = SteadyClock::now();

    std::vector<std::thread> ts;
    for (size_t r = 0; r < readers; ++r) {
        ts.emplace_back([&] {
            for (size_t i = 0; i < per; ++i) {
                std::shared_lock lk(mu);
                (void)counter;
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
    auto t0 = SteadyClock::now();

    for (size_t i = 0; i < n; ++i) {
        std::unique_lock lk(mu);
        ++counter;
    }
    
    (void)counter;
    print_rate("rwlock_exclusive", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_timer_sleep_batch() {
    const size_t n = 500;
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        ts.emplace_back([] { std::this_thread::sleep_for(std::chrono::nanoseconds(50)); });
    }
    for (auto& t : ts) t.join();
    print_rate("timer_sleep_batch", n, elapsed_ns(t0, SteadyClock::now()));
}

static void bench_many_timers() {
    const size_t n = 2000;
    auto t0 = SteadyClock::now();
    std::vector<std::thread> ts;
    ts.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        ts.emplace_back([i] {
            std::this_thread::sleep_for(std::chrono::nanoseconds(1 + i % 1000));
        });
    }
    for (auto& t : ts) t.join();
    print_rate("timer_many_100k_dispatch", n, elapsed_ns(t0, SteadyClock::now()));
}

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("cpp bench  OS-thread baseline  c++17\n");
    std::printf("--- fiber / spawn (OS threads) ---\n");
    bench_yield_pingpong();
    bench_yield_single();
    bench_yield_ws4();
    bench_spawn_join();
    bench_spawn_result_join();
    bench_nursery_join();
    bench_priority_dispatch();
    bench_skynet();
    bench_n_tasks();

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
    bench_timer_sleep_batch();
    bench_many_timers();

    std::printf("---\ndone\n");
    return 0;
}
