///|
async test "a fetch that never gets a response times out with the typed error" {
  // A local listener that accepts and then holds the connection open
  // without ever answering. Upstream's HTTP client has no timeout of its
  // own, so the one-second bound is the only thing that ends this fetch —
  // and it must end as the typed FetchError::TimedOut, not as an eternal
  // wait or an upstream error. The listener task is no_wait, the pattern
  // moonbitlang/async's own socket tests use, so it does not hold the
  // task group open.
  let server = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let port = server.addr.port()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever((_, _) => {
        for ;; {
          @async.sleep(10_000)
        }
      })
    }
    try {
      let _ = @fetch.fetch_ics(
        "http://127.0.0.1:\{port}/ics",
        timeout_seconds=1,
      )
      fail("expected the fetch to time out")
    } catch {
      @fetch.FetchError::TimedOut(seconds=s, url=u) => {
        assert_eq(s, 1)
        assert_true(u.has_prefix("http://127.0.0.1:"))
      }
      _ => fail("expected TimedOut, not another error")
    }
  })
}
