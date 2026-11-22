fn main raise {
  let args = @env.args()
  guard args.length() > 1 else {
    return
  }
  let mut idx = 0
  for part in args[1].to_string_view().split("\n") {
    let line = part.trim(chars=" \r".to_string_view())
    if line == "" {
      continue
    }
    let sep = line.to_string_view().find("\t".to_string_view())
    guard sep is Some(pos) else {
      continue
    }
    // 每条独立 catch:解析/展开拒绝的规则标记 REFUSED(拒绝本身是正确行为,
    // 不与 dateutil 对拍),批次继续而不是中止。
    let outcome = try {
      let dtstart_line = "DTSTART:" + line.clamped_view(start=0, end=pos).to_owned()
      let rule_text = line.clamped_view(start=pos + 1).to_owned()
      let zones = @model.ZoneTable::with_builtin(@model.build_zone_table([]))
      let dtline = @text.parse_content_line(dtstart_line, 0)
      let dt = @model.parse_date_time(dtline, zones)
      let rule = @rrule.parse_rule(rule_text)
      let occ = @rrule.expand(rule, dt, limit=60)
      let out = StringBuilder()
      for o in occ {
        out.write_string(o.to_string())
        out.write_string(",")
      }
      "OK:\{out}"
    } catch {
      _ => "REFUSED"
    }
    println("\{idx}:\{outcome}")
    idx = idx + 1
  }
}
