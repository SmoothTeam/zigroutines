package main

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

func printRate(name string, ops int, dt time.Duration) {
	if ops == 0 {
		fmt.Printf("%s: 0 ops\n", name)
		return
	}
	dtNs := float64(dt.Nanoseconds())
	if dtNs < 1 {
		dtNs = 1
	}
	nsPer := dtNs / float64(ops)
	opsPerNs := float64(ops) / dtNs
	mops := float64(ops) / (dtNs / 1e3)
	fmt.Printf("%s: %d ops in %.3f ms → %.1f ns/op  (%.6f ops/ns, %.2f Mops/s)\n",
		name, ops, float64(dt.Microseconds())/1000.0, nsPer, opsPerNs, mops)
}

func printThroughput(name string, ops int, dt time.Duration, unit string) {
	perS := float64(ops) / dt.Seconds()
	fmt.Printf("%s: %d %s in %.3f ms → %.0f %s/s\n",
		name, ops, unit, float64(dt.Microseconds())/1000.0, perS, unit)
}

func main() {
	fmt.Printf("go bench  go=%s  GOMAXPROCS=%d\n", runtime.Version(), runtime.GOMAXPROCS(0))
	fmt.Println("--- fiber / spawn ---")
	benchYieldPingPong()
	benchYieldSingle()
	benchYieldWS4()
	benchSpawnJoin()
	benchSpawnResultJoin()
	benchNurseryJoin()
	benchPriorityDispatch()
	benchSkynet()
	benchNTasks()

	fmt.Println("--- channel / actor ---")
	benchChanPipeline()
	benchChanRendezvous()
	benchChanMpmc()
	benchChanTryUncontended()
	benchChanCreate()
	benchChanClosedDrain()
	benchChanProdConsWork()
	benchChanPopular()
	benchChanSem()
	benchActorMailbox()

	fmt.Println("--- select ---")
	benchSelectFanIn()
	benchSelectUncontended()
	benchSelectNonblock()
	benchSelectSyncContended()

	fmt.Println("--- sync ---")
	benchMutexUncontended()
	benchMutexContended()
	benchSemHandoff()
	benchRwLockShared()
	benchRwLockExclusive()

	fmt.Println("--- timers ---")
	benchTimerSleepBatch()
	benchManyTimers()

	fmt.Println("---")
	fmt.Println("done")
}

func benchYieldPingPong() {
	const n = 200_000
	var wg sync.WaitGroup
	wg.Add(2)
	remain := int64(n)
	t0 := time.Now()
	go func() {
		defer wg.Done()
		for atomic.AddInt64(&remain, -1) >= 0 {
			runtime.Gosched()
		}
	}()
	go func() {
		defer wg.Done()
		for atomic.AddInt64(&remain, -1) >= 0 {
			runtime.Gosched()
		}
	}()
	wg.Wait()
	printRate("yield_pingpong", n*2, time.Since(t0))
}

func benchYieldSingle() {
	const n = 500_000
	t0 := time.Now()
	done := make(chan struct{})
	go func() {
		for i := 0; i < n; i++ {
			runtime.Gosched()
		}
		close(done)
	}()
	<-done
	printRate("yield_single", n, time.Since(t0))
}

func benchYieldWS4() {
	const workers = 4
	const n = 20_000
	var wg sync.WaitGroup
	wg.Add(workers)
	t0 := time.Now()
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for i := 0; i < n; i++ {
				runtime.Gosched()
			}
		}()
	}
	wg.Wait()
	printRate("yield_ws_4w", n*workers, time.Since(t0))
}

func benchSpawnJoin() {
	const n = 10_000
	t0 := time.Now()
	for i := 0; i < n; i++ {
		var wg sync.WaitGroup
		wg.Add(1)
		go func() { wg.Done() }()
		wg.Wait()
	}
	printRate("spawn_join", n, time.Since(t0))
}

func benchSpawnResultJoin() {
	const n = 5_000
	t0 := time.Now()
	acc := uint32(0)
	for i := 0; i < n; i++ {
		ch := make(chan uint32, 1)
		i := i
		go func() { ch <- uint32(i) + 1 }()
		acc += <-ch
	}
	_ = acc
	printRate("spawn_result_join", n, time.Since(t0))
}

func benchNurseryJoin() {
	const n = 2_000
	t0 := time.Now()
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() { wg.Done() }()
	}
	wg.Wait()
	printRate("nursery_join", n, time.Since(t0))
}

func benchPriorityDispatch() {
	const n = 5_000
	t0 := time.Now()
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() { wg.Done() }()
	}
	wg.Wait()
	printRate("priority_dispatch", n, time.Since(t0))
}

func skynet(num, size int) int {
	if size == 1 {
		return num
	}
	const div = 10
	next := size / div
	ch := make(chan int, div)
	for i := 0; i < div; i++ {
		i := i
		go func() { ch <- skynet(num+i*next, next) }()
	}
	sum := 0
	for i := 0; i < div; i++ {
		sum += <-ch
	}
	return sum
}

func benchSkynet() {
	const size = 10_000
	t0 := time.Now()
	_ = skynet(0, size)
	totalSpawns := size + size/10 + size/100 + size/1000 + size/10000
	printRate("skynet_join_10k", totalSpawns, time.Since(t0))
}

func benchNTasks() {
	counts := []int{1_000, 10_000, 50_000}
	const rounds = 20
	for _, n := range counts {
		var wg sync.WaitGroup
		wg.Add(n)
		t0 := time.Now()
		for i := 0; i < n; i++ {
			go func() {
				for r := 0; r < rounds; r++ {
					runtime.Gosched()
				}
				wg.Done()
			}()
		}
		wg.Wait()
		printRate(fmt.Sprintf("n_tasks_%d", n), n*rounds, time.Since(t0))
	}
}

func benchChanPipeline() {
	const n = 200_000
	ch := make(chan int, 256)
	t0 := time.Now()
	go func() {
		for i := 0; i < n; i++ {
			ch <- i
		}
		close(ch)
	}()
	for range ch {
	}
	printRate("chan_pipeline_buf256", n, time.Since(t0))
}

func benchChanRendezvous() {
	const n = 100_000
	ch := make(chan int)
	t0 := time.Now()
	go func() {
		for i := 0; i < n; i++ {
			ch <- i
		}
		close(ch)
	}()
	for range ch {
	}
	printRate("chan_rendezvous", n, time.Since(t0))
}

func benchChanMpmc() {
	const producers, consumers, per = 4, 4, 25_000
	total := producers * per
	ch := make(chan int, 1024)
	var done atomic.Int32
	t0 := time.Now()
	for p := 0; p < producers; p++ {
		go func() {
			for i := 0; i < per; i++ {
				ch <- i
			}
			if done.Add(1) == producers {
				close(ch)
			}
		}()
	}
	var wg sync.WaitGroup
	wg.Add(consumers)
	for c := 0; c < consumers; c++ {
		go func() {
			defer wg.Done()
			for range ch {
			}
		}()
	}
	wg.Wait()
	printRate("chan_mpmc_4x4", total, time.Since(t0))
}

func benchChanTryUncontended() {
	const n = 500_000
	ch := make(chan int, 1)
	t0 := time.Now()
	for i := 0; i < n; i++ {
		select {
		case ch <- i:
		default:
		}
		select {
		case <-ch:
		default:
		}
	}
	printRate("chan_try_uncontended", n, time.Since(t0))
}

func benchChanCreate() {
	const n = 50_000
	t0 := time.Now()
	for i := 0; i < n; i++ {
		ch := make(chan int, 8)
		_ = ch
	}
	printRate("chan_create_buf8", n, time.Since(t0))
}

func benchChanClosedDrain() {
	const n = 100_000
	ch := make(chan int, n)
	for i := 0; i < n; i++ {
		ch <- i
	}
	close(ch)
	t0 := time.Now()
	for range ch {
	}
	printRate("chan_closed_drain", n, time.Since(t0))
}

func benchChanProdConsWork() {
	const n, work = 50_000, 100
	ch := make(chan int, 64)
	spin := func() {
		foo := 0
		for i := 0; i < work; i++ {
			foo *= 2
			foo /= 2
		}
		_ = foo
	}
	t0 := time.Now()
	go func() {
		for i := 0; i < n; i++ {
			spin()
			ch <- i
		}
		close(ch)
	}()
	for range ch {
		spin()
	}
	printRate("chan_prodcons_work", n, time.Since(t0))
}

func benchChanPopular() {
	const waiters, msgs = 256, 1000
	ch := make(chan int)
	var wg sync.WaitGroup
	wg.Add(waiters)
	t0 := time.Now()
	for w := 0; w < waiters; w++ {
		go func() {
			defer wg.Done()
			for i := 0; i < msgs; i++ {
				<-ch
			}
		}()
	}
	go func() {
		for i := 0; i < waiters*msgs; i++ {
			ch <- i
		}
		close(ch)
	}()
	wg.Wait()
	printRate("chan_popular_256", waiters*msgs, time.Since(t0))
}

func benchChanSem() {
	const n = 100_000
	ch := make(chan struct{}, 1)
	t0 := time.Now()
	for i := 0; i < n; i++ {
		ch <- struct{}{}
		<-ch
	}
	printRate("chan_sem", n, time.Since(t0))
}

func benchActorMailbox() {
	const n = 50_000
	ch := make(chan uint64, 256)
	var sum uint64
	done := make(chan struct{})
	t0 := time.Now()
	go func() {
		for v := range ch {
			sum += v
		}
		close(done)
	}()
	for i := uint64(0); i < n; i++ {
		ch <- i
	}
	close(ch)
	<-done
	_ = sum
	printRate("actor_mailbox", n, time.Since(t0))
}

func benchSelectFanIn() {
	const n = 50_000
	a := make(chan int, 64)
	b := make(chan int, 64)
	t0 := time.Now()
	go func() {
		for i := 0; i < n/2; i++ {
			a <- i
		}
	}()
	go func() {
		for i := 0; i < n-n/2; i++ {
			b <- i
		}
	}()
	got := 0
	for got < n {
		select {
		case <-a:
			got++
		case <-b:
			got++
		}
	}
	printRate("select_fanin_2", n, time.Since(t0))
}

func benchSelectUncontended() {
	const n = 100_000
	a := make(chan int, 1)
	b := make(chan int, 1)
	a <- 0
	t0 := time.Now()
	for i := 0; i < n; i++ {
		select {
		case <-a:
			b <- 0
		case <-b:
			a <- 0
		}
	}
	printRate("select_uncontended", n, time.Since(t0))
}

func benchSelectNonblock() {
	const n = 200_000
	a := make(chan int)
	b := make(chan int)
	t0 := time.Now()
	for i := 0; i < n; i++ {
		select {
		case <-a:
		case <-b:
		default:
		}
	}
	printRate("select_nonblock", n, time.Since(t0))
}

func benchSelectSyncContended() {
	const n = 30_000
	a := make(chan int, 32)
	b := make(chan int, 32)
	c := make(chan int, 32)
	t0 := time.Now()
	go func() {
		for i := 0; i < n/3; i++ {
			a <- i
		}
	}()
	go func() {
		for i := 0; i < n/3; i++ {
			b <- i
		}
	}()
	go func() {
		for i := 0; i < n-2*(n/3); i++ {
			c <- i
		}
	}()
	got := 0
	for got < n {
		select {
		case <-a:
			got++
		case <-b:
			got++
		case <-c:
			got++
		}
	}
	printRate("select_sync_contended", n, time.Since(t0))
}

func benchMutexUncontended() {
	const n = 200_000
	var mu sync.Mutex
	t0 := time.Now()
	for i := 0; i < n; i++ {
		mu.Lock()
		mu.Unlock()
	}
	printRate("mutex_uncontended", n, time.Since(t0))
}

func benchMutexContended() {
	const workers, per = 4, 25_000
	var mu sync.Mutex
	var counter int
	var wg sync.WaitGroup
	wg.Add(workers)
	t0 := time.Now()
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for i := 0; i < per; i++ {
				mu.Lock()
				counter++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	printRate("mutex_contended_4", workers*per, time.Since(t0))
}

func benchSemHandoff() {
	const n = 50_000
	sem := make(chan struct{}, n)
	t0 := time.Now()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < n; i++ {
			<-sem
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < n; i++ {
			sem <- struct{}{}
		}
	}()
	wg.Wait()
	printRate("sem_handoff", n, time.Since(t0))
}

func benchRwLockShared() {
	const readers, per = 4, 50_000
	var mu sync.RWMutex
	var counter int
	var wg sync.WaitGroup
	wg.Add(readers)
	t0 := time.Now()
	for r := 0; r < readers; r++ {
		go func() {
			defer wg.Done()
			for i := 0; i < per; i++ {
				mu.RLock()
				_ = counter
				mu.RUnlock()
			}
		}()
	}
	wg.Wait()
	printRate("rwlock_shared_4", readers*per, time.Since(t0))
}

func benchRwLockExclusive() {
	const n = 100_000
	var mu sync.RWMutex
	var counter int
	t0 := time.Now()
	for i := 0; i < n; i++ {
		mu.Lock()
		counter++
		mu.Unlock()
	}
	_ = counter
	printRate("rwlock_exclusive", n, time.Since(t0))
}

func benchTimerSleepBatch() {
	const n = 2_000
	var wg sync.WaitGroup
	wg.Add(n)
	t0 := time.Now()
	for i := 0; i < n; i++ {
		go func() {
			time.Sleep(50 * time.Nanosecond)
			wg.Done()
		}()
	}
	wg.Wait()
	printRate("timer_sleep_batch", n, time.Since(t0))
}

func benchManyTimers() {
	const n = 100_000
	var wg sync.WaitGroup
	wg.Add(n)
	t0 := time.Now()
	for i := 0; i < n; i++ {
		d := time.Duration(1+i%1000) * time.Nanosecond
		go func(d time.Duration) {
			time.Sleep(d)
			wg.Done()
		}(d)
	}
	wg.Wait()
	printRate("timer_many_100k_dispatch", n, time.Since(t0))
}

var _ = printThroughput
