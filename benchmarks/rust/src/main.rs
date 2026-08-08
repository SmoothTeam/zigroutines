use crossbeam_channel as cb;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn print_rate(name: &str, ops: usize, dt: Duration) {
    if ops == 0 {
        println!("{name}: 0 ops");
        return;
    }
    let dt_ns = dt.as_nanos().max(1) as f64;
    let ops_f = ops as f64;
    let ns_per = dt_ns / ops_f;
    let ops_per_ns = ops_f / dt_ns;
    let mops = ops_f / (dt_ns / 1e3);
    println!(
        "{name}: {ops} ops in {:.3} ms → {ns_per:.1} ns/op  ({ops_per_ns:.6} ops/ns, {mops:.2} Mops/s)",
        dt.as_secs_f64() * 1e3
    );
}

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .unwrap()
}

fn main() {
    println!(
        "rust bench  rustc={}  tokio multi-thread",
        rustc_version_runtime()
    );

    println!("--- fiber / spawn ---");
    bench_yield_pingpong();
    bench_yield_single();
    bench_yield_ws4();
    bench_spawn_join();
    bench_spawn_result_join();
    bench_nursery_join();
    bench_priority_dispatch();
    bench_skynet();
    bench_n_tasks();

    println!("--- channel / actor ---");
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

    println!("--- select ---");
    bench_select_fanin();
    bench_select_uncontended();
    bench_select_nonblock();
    bench_select_sync_contended();

    println!("--- sync ---");
    bench_mutex_uncontended();
    bench_mutex_contended();
    bench_sem_handoff();
    bench_rwlock_shared();
    bench_rwlock_exclusive();

    println!("--- timers ---");
    bench_timer_sleep_batch();
    bench_many_timers();

    println!("---");
    println!("done");
}

fn rustc_version_runtime() -> String {
    option_env!("CARGO_PKG_RUST_VERSION")
        .unwrap_or("stable")
        .to_string()
}

// fiber/spawn

fn bench_yield_pingpong() {
    let n = 200_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let remain = Arc::new(AtomicUsize::new(n * 2));
        let a = {
            let remain = remain.clone();
            tokio::spawn(async move {
                loop {
                    let prev = remain.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                        if v == 0 {
                            None
                        } else {
                            Some(v - 1)
                        }
                    });
                    if prev.is_err() {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
        };
        let b = {
            let remain = remain.clone();
            tokio::spawn(async move {
                loop {
                    let prev = remain.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| {
                        if v == 0 {
                            None
                        } else {
                            Some(v - 1)
                        }
                    });
                    if prev.is_err() {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
        };
        let _ = tokio::join!(a, b);
    });
    print_rate("yield_pingpong", n * 2, t0.elapsed());
}

fn bench_yield_single() {
    let n = 500_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        for _ in 0..n {
            tokio::task::yield_now().await;
        }
    });
    print_rate("yield_single", n, t0.elapsed());
}

fn bench_yield_ws4() {
    let workers = 4usize;
    let n = 20_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut handles = Vec::new();
        for _ in 0..workers {
            handles.push(tokio::spawn(async move {
                for _ in 0..n {
                    tokio::task::yield_now().await;
                }
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
    });
    print_rate("yield_ws_4w", n * workers, t0.elapsed());
}

fn bench_spawn_join() {
    let n = 10_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        for _ in 0..n {
            tokio::spawn(async {}).await.unwrap();
        }
    });
    print_rate("spawn_join", n, t0.elapsed());
}

fn bench_spawn_result_join() {
    let n = 5_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut acc = 0u32;
        for i in 0..n {
            let h = tokio::spawn(async move { i as u32 + 1 });
            acc = acc.wrapping_add(h.await.unwrap());
        }
        std::hint::black_box(acc);
    });
    print_rate("spawn_result_join", n, t0.elapsed());
}

fn bench_nursery_join() {
    let n = 2_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut handles = Vec::with_capacity(n);
        for _ in 0..n {
            handles.push(tokio::spawn(async {}));
        }
        for h in handles {
            h.await.unwrap();
        }
    });
    print_rate("nursery_join", n, t0.elapsed());
}

fn bench_priority_dispatch() {
    let n = 5_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut handles = Vec::with_capacity(n);
        for _ in 0..n {
            handles.push(tokio::spawn(async {}));
        }
        for h in handles {
            h.await.unwrap();
        }
    });
    print_rate("priority_dispatch", n, t0.elapsed());
}

fn skynet(num: usize, size: usize) -> usize {
    if size == 1 {
        return num;
    }
    let div = 10;
    let next = size / div;
    let mut handles = Vec::with_capacity(div);
    for i in 0..div {
        let n0 = num + i * next;
        handles.push(thread::spawn(move || skynet(n0, next)));
    }
    handles.into_iter().map(|h| h.join().unwrap()).sum()
}

fn bench_skynet() {
    let size = 10_000usize;
    let t0 = Instant::now();
    let _ = skynet(0, size);
    let total = size + size / 10 + size / 100 + size / 1000 + size / 10_000;
    print_rate("skynet_join_10k", total, t0.elapsed());
}

fn bench_n_tasks() {
    let runtime = rt();
    for n in [1_000usize, 10_000, 50_000] {
        let rounds = 20usize;
        let t0 = Instant::now();
        runtime.block_on(async {
            let mut handles = Vec::with_capacity(n);
            for _ in 0..n {
                handles.push(tokio::spawn(async move {
                    for _ in 0..rounds {
                        tokio::task::yield_now().await;
                    }
                }));
            }
            for h in handles {
                h.await.unwrap();
            }
        });
        print_rate(&format!("n_tasks_{n}"), n * rounds, t0.elapsed());
    }
}

// channels

fn bench_chan_pipeline() {
    let n = 200_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let (tx, mut rx) = mpsc::channel::<usize>(256);
        let prod = tokio::spawn(async move {
            for i in 0..n {
                tx.send(i).await.unwrap();
            }
        });
        let cons = tokio::spawn(async move {
            while rx.recv().await.is_some() {}
        });
        let _ = tokio::join!(prod, cons);
    });
    print_rate("chan_pipeline_buf256", n, t0.elapsed());
}

fn bench_chan_rendezvous() {
    let n = 100_000usize;
    let (tx, rx) = cb::bounded::<usize>(0);
    let t0 = Instant::now();
    let prod = thread::spawn(move || {
        for i in 0..n {
            tx.send(i).unwrap();
        }
    });
    let cons = thread::spawn(move || {
        while rx.recv().is_ok() {}
    });
    prod.join().unwrap();
    cons.join().unwrap();
    print_rate("chan_rendezvous", n, t0.elapsed());
}

fn bench_chan_mpmc() {
    let producers = 4usize;
    let consumers = 4usize;
    let per = 25_000usize;
    let total = producers * per;
    let (tx, rx) = cb::bounded::<usize>(1024);
    let done = Arc::new(AtomicUsize::new(0));
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..producers {
        let tx = tx.clone();
        let done = done.clone();
        handles.push(thread::spawn(move || {
            for i in 0..per {
                tx.send(i).unwrap();
            }
            if done.fetch_add(1, Ordering::Relaxed) + 1 == producers {
                drop(tx);
            }
        }));
    }
    drop(tx);
    for _ in 0..consumers {
        let rx = rx.clone();
        handles.push(thread::spawn(move || {
            while rx.recv().is_ok() {}
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    print_rate("chan_mpmc_4x4", total, t0.elapsed());
}

fn bench_chan_try_uncontended() {
    let n = 500_000usize;
    let (tx, rx) = cb::bounded::<usize>(1);
    let t0 = Instant::now();
    for i in 0..n {
        let _ = tx.try_send(i);
        let _ = rx.try_recv();
    }
    print_rate("chan_try_uncontended", n, t0.elapsed());
}

fn bench_chan_create() {
    let n = 50_000usize;
    let t0 = Instant::now();
    for _ in 0..n {
        let (_tx, _rx) = mpsc::channel::<usize>(8);
    }
    print_rate("chan_create_buf8", n, t0.elapsed());
}

fn bench_chan_closed_drain() {
    let n = 100_000usize;
    let (tx, rx) = cb::bounded::<usize>(n);
    for i in 0..n {
        tx.send(i).unwrap();
    }
    drop(tx);
    let t0 = Instant::now();
    while rx.recv().is_ok() {}
    print_rate("chan_closed_drain", n, t0.elapsed());
}

fn bench_chan_prodcons_work() {
    let n = 50_000usize;
    let work = 100usize;
    let (tx, rx) = cb::bounded::<usize>(64);
    let spin = move || {
        let mut foo = 0usize;
        for _ in 0..work {
            foo = foo.wrapping_mul(2) / 2;
        }
        std::hint::black_box(foo);
    };
    let t0 = Instant::now();
    let spin_p = spin;
    let spin_c = spin;
    let prod = thread::spawn(move || {
        for i in 0..n {
            spin_p();
            tx.send(i).unwrap();
        }
    });
    let cons = thread::spawn(move || {
        while rx.recv().is_ok() {
            spin_c();
        }
    });
    prod.join().unwrap();
    cons.join().unwrap();
    print_rate("chan_prodcons_work", n, t0.elapsed());
}

fn bench_chan_popular() {
    let waiters = 256usize;
    let msgs = 1_000usize;
    let (tx, rx) = cb::bounded::<usize>(0);
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..waiters {
        let rx = rx.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..msgs {
                let _ = rx.recv();
            }
        }));
    }
    handles.push(thread::spawn(move || {
        for i in 0..waiters * msgs {
            tx.send(i).unwrap();
        }
    }));
    for h in handles {
        h.join().unwrap();
    }
    print_rate("chan_popular_256", waiters * msgs, t0.elapsed());
}

fn bench_chan_sem() {
    let n = 100_000usize;
    let (tx, rx) = cb::bounded::<()>(1);
    let t0 = Instant::now();
    for _ in 0..n {
        tx.send(()).unwrap();
        rx.recv().unwrap();
    }
    print_rate("chan_sem", n, t0.elapsed());
}

fn bench_actor_mailbox() {
    let n = 50_000usize;
    let (tx, rx) = cb::bounded::<u64>(256);
    let t0 = Instant::now();
    let actor = thread::spawn(move || {
        let mut sum = 0u64;
        while let Ok(v) = rx.recv() {
            sum = sum.wrapping_add(v);
        }
        sum
    });
    for i in 0..n as u64 {
        tx.send(i).unwrap();
    }
    drop(tx);
    let _ = actor.join().unwrap();
    print_rate("actor_mailbox", n, t0.elapsed());
}

// select

fn bench_select_fanin() {
    let n = 50_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let (ta, mut ra) = mpsc::channel::<usize>(64);
        let (tb, mut rb) = mpsc::channel::<usize>(64);
        let pa = tokio::spawn(async move {
            for i in 0..n / 2 {
                ta.send(i).await.unwrap();
            }
        });
        let pb = tokio::spawn(async move {
            for i in 0..n - n / 2 {
                tb.send(i).await.unwrap();
            }
        });
        let mut got = 0usize;
        while got < n {
            tokio::select! {
                v = ra.recv() => { if v.is_some() { got += 1; } }
                v = rb.recv() => { if v.is_some() { got += 1; } }
            }
        }
        let _ = tokio::join!(pa, pb);
    });
    print_rate("select_fanin_2", n, t0.elapsed());
}

fn bench_select_uncontended() {
    let n = 100_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let (ta, mut ra) = mpsc::channel::<usize>(1);
        let (tb, mut rb) = mpsc::channel::<usize>(1);
        ta.send(0).await.unwrap();
        for _ in 0..n {
            tokio::select! {
                v = ra.recv() => {
                    if v.is_some() { tb.send(0).await.unwrap(); }
                }
                v = rb.recv() => {
                    if v.is_some() { ta.send(0).await.unwrap(); }
                }
            }
        }
    });
    print_rate("select_uncontended", n, t0.elapsed());
}

fn bench_select_nonblock() {
    let n = 200_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let (ta, mut ra) = mpsc::channel::<usize>(1);
        let (tb, mut rb) = mpsc::channel::<usize>(1);
        drop(ta);
        drop(tb);
        for _ in 0..n {
            tokio::select! {
                biased;
                v = ra.recv() => { std::hint::black_box(v); }
                v = rb.recv() => { std::hint::black_box(v); }
            }
        }
    });
    print_rate("select_nonblock", n, t0.elapsed());
}

fn bench_select_sync_contended() {
    let n = 30_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let (ta, mut ra) = mpsc::channel::<usize>(32);
        let (tb, mut rb) = mpsc::channel::<usize>(32);
        let (tc, mut rc) = mpsc::channel::<usize>(32);
        let per = n / 3;
        let fa = tokio::spawn(async move {
            for i in 0..per {
                ta.send(i).await.unwrap();
            }
        });
        let fb = tokio::spawn(async move {
            for i in 0..per {
                tb.send(i).await.unwrap();
            }
        });
        let fc = tokio::spawn(async move {
            for i in 0..(n - 2 * per) {
                tc.send(i).await.unwrap();
            }
        });
        let mut got = 0usize;
        while got < n {
            tokio::select! {
                v = ra.recv() => { if v.is_some() { got += 1; } }
                v = rb.recv() => { if v.is_some() { got += 1; } }
                v = rc.recv() => { if v.is_some() { got += 1; } }
            }
        }
        let _ = tokio::join!(fa, fb, fc);
    });
    print_rate("select_sync_contended", n, t0.elapsed());
}

// sync

fn bench_mutex_uncontended() {
    let n = 200_000usize;
    let mu = Mutex::new(());
    let t0 = Instant::now();
    for _ in 0..n {
        let _g = mu.lock().unwrap();
    }
    print_rate("mutex_uncontended", n, t0.elapsed());
}

fn bench_mutex_contended() {
    let workers = 4usize;
    let per = 25_000usize;
    let mu = Arc::new(Mutex::new(0usize));
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..workers {
        let mu = mu.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..per {
                let mut g = mu.lock().unwrap();
                *g += 1;
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    print_rate("mutex_contended_4", workers * per, t0.elapsed());
}

fn bench_sem_handoff() {
    let n = 50_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let sem = Arc::new(tokio::sync::Semaphore::new(0));
        let s1 = sem.clone();
        let s2 = sem.clone();
        let cons = tokio::spawn(async move {
            for _ in 0..n {
                let _p = s1.acquire().await.unwrap();
            }
        });
        let prod = tokio::spawn(async move {
            for _ in 0..n {
                s2.add_permits(1);
            }
        });
        let _ = tokio::join!(cons, prod);
    });
    print_rate("sem_handoff", n, t0.elapsed());
}

fn bench_rwlock_shared() {
    let readers = 4usize;
    let per = 50_000usize;
    let lock = Arc::new(RwLock::new(0usize));
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..readers {
        let lock = lock.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..per {
                let g = lock.read().unwrap();
                std::hint::black_box(*g);
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    print_rate("rwlock_shared_4", readers * per, t0.elapsed());
}

fn bench_rwlock_exclusive() {
    let n = 100_000usize;
    let lock = RwLock::new(0usize);
    let t0 = Instant::now();
    for _ in 0..n {
        let mut g = lock.write().unwrap();
        *g += 1;
    }
    print_rate("rwlock_exclusive", n, t0.elapsed());
}

fn bench_timer_sleep_batch() {
    let n = 2_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut handles = Vec::with_capacity(n);
        for _ in 0..n {
            handles.push(tokio::spawn(async {
                tokio::time::sleep(Duration::from_nanos(50)).await;
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
    });
    print_rate("timer_sleep_batch", n, t0.elapsed());
}

fn bench_many_timers() {
    let n = 100_000usize;
    let runtime = rt();
    let t0 = Instant::now();
    runtime.block_on(async {
        let mut handles = Vec::with_capacity(n);
        for i in 0..n {
            let d = Duration::from_nanos(1 + (i % 1000) as u64);
            handles.push(tokio::spawn(async move {
                tokio::time::sleep(d).await;
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
    });
    print_rate("timer_many_100k_dispatch", n, t0.elapsed());
}
