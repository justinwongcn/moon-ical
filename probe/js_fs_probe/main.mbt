///|
/// S1 upstream probe (see docs/upstream-seams.md):
///
///   moon run probe/js_fs_probe --target js
///   moon run probe/js_fs_probe --target native
///
/// Today `moonbitlang/async/fs` is native-only; on --target js this is
/// expected to FAIL to compile. The moment it compiles AND prints
/// PROBE_OK on js, upstream has shipped JS fs support: delete
/// ical/store/js_shim.mbt and let ical/store/native.mbt serve the js
/// target too (seam S1 switch recipe).

async fn main {
  let path = "probe_js_fs.tmp"
  @fs.write_file(path, "moon-ical probe")
  let content = @fs.read_file(path).text()
  @fs.remove(path)
  println("PROBE_OK content=\{content}")
}
