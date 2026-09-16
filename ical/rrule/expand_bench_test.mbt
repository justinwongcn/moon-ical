///|
test "bench expand monthly occurrences=10000 dense_bymonthday" (it : @bench.T) {
  let rule = @rrule.parse_rule(
    "FREQ=MONTHLY;BYMONTHDAY=31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1",
  )
  let start = @model.parse_single_date_time(
    "20000101T090000Z",
    @model.ZoneTable::empty(),
  )
  it.bench(() => {
    let occurrences = try! @rrule.expand(rule, start, limit=10000)
    it.keep(occurrences)
  })
}
