///|
/// A vdir collection on disk: one `.ics` file per event under `root`,
/// the layout the vdir convention defines — the same shape Radicale
/// stores and every vdir-aware tool reads, so the collection this
/// server keeps is portable by construction.
///
/// The layer is deliberately flat: an event is a name and its bytes.
/// Interpreting the bytes as components is `ical/model`'s job; serving
/// them is `ical/httpd`'s. What this layer owns is durability and the
/// ETag contract: an ETag is the content hash of exactly the bytes a
/// GET returns, so clients can trust `If-Match` / `If-None-Match`
/// reasoning (S6 wires those headers).
pub struct VdirStore {
  root : String
}

///|
/// A file read back from the store: its bytes and the ETag those exact
/// bytes hash to.
pub(all) struct VdirFile {
  text : String
  etag : String
} derive(Debug, Eq)

///|
/// Why a store call failed. `BadName` carries the refused name so the
/// HTTP layer can answer 404/400 without echoing a path anywhere near a
/// filesystem.
pub(all) suberror StoreError {
  BadName(name~ : String)
} derive(Debug, Eq)

///|
pub impl Show for StoreError with fn output(self, logger) {
  match self {
    BadName(name=n) => logger.write_string("refused store name: \{n}")
  }
}

///|
/// Open (or designate) the collection rooted at `root`. The directory
/// is created on demand at the first write rather than here, so
/// pointing a store at a not-yet-existing path is not an error — a
/// fresh calendar starts empty.
pub fn VdirStore::new(root : String) -> VdirStore {
  { root, }
}

///|
/// Write one event's bytes under `name` and return the ETag of the
/// stored content. The write is atomic in the vdir sense: the file is
/// replaced wholesale, never edited in place, so a reader sees either
/// the old complete event or the new one.
pub async fn VdirStore::put(
  self : VdirStore,
  name : String,
  text : String,
) -> String {
  check_name(name)
  // mkdir refuses an existing target even with recursive=true, so the
  // directory is created only when absent — a fresh calendar on first
  // write, an untouched one afterwards.
  if !@fs.exists(self.root) {
    @fs.mkdir(self.root, recursive=true)
  }
  @fs.write_file(path_of(self.root, name), text)
  etag_of(text)
}

///|
/// Read one event back. `None` means the calendar has no event under
/// that name — absence is not breakage.
pub async fn VdirStore::get(self : VdirStore, name : String) -> VdirFile? {
  check_name(name)
  let path = path_of(self.root, name)
  if @fs.exists(path) {
    let data = @fs.read_file(path)
    let text = data.text()
    Some({ text, etag: etag_of(text), })
  } else {
    None
  }
}

///|
/// Remove one event. `false` when there was nothing under that name.
pub async fn VdirStore::delete(self : VdirStore, name : String) -> Bool {
  check_name(name)
  let path = path_of(self.root, name)
  if @fs.exists(path) {
    @fs.remove(path)
    true
  } else {
    false
  }
}

///|
/// Every event name in the collection, sorted — the listing a
/// calendar-collection PROPFIND (S6) walks.
pub async fn VdirStore::list(self : VdirStore) -> Array[String] {
  if @fs.exists(self.root) {
    let names = @fs.readdir(self.root)
    names.sort()
    names
  } else {
    []
  }
}

///|
/// The ETag of some content: a stable FNV-1a 64 hash of its UTF-8
/// bytes, hex-encoded. Content-addressed on purpose — identical bytes
/// always map to the identical ETag, any change moves it — which is
/// exactly the property `If-Match` semantics need. Callers quote it on
/// the wire (`"\{etag}"`).
pub fn etag_of(text : String) -> String {
  // FNV-1a 64-bit: offset basis, then per byte: hash ^= byte;
  // hash *= prime. Arithmetic stays in UInt64.
  let mut hash : UInt64 = 0xcbf29ce484222325
  for b in text.to_array() {
    let code = b.to_int()
    // Encode this character's UTF-8 bytes into the hash directly,
    // avoiding a Bytes round-trip for what is a byte-order-insensitive
    // content fingerprint.
    if code < 0x80 {
      hash = fnv_step(hash, code)
    } else {
      for part in utf8_bytes(code) {
        hash = fnv_step(hash, part)
      }
    }
  }
  hash.to_string()
}

///|
fn fnv_step(hash : UInt64, byte : Int) -> UInt64 {
  (hash ^ byte.to_uint64()) * 0x100000001b3
}

///|
/// The UTF-8 encoding of one code point, byte by byte.
fn utf8_bytes(code : Int) -> Array[Int] {
  if code < 0x800 {
    [0xC0 | (code >> 6), 0x80 | (code & 0x3F)]
  } else if code < 0x10000 {
    [0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F)]
  } else {
    [
      0xF0 | (code >> 18),
      0x80 | ((code >> 12) & 0x3F),
      0x80 | ((code >> 6) & 0x3F),
      0x80 | (code & 0x3F),
    ]
  }
}

///|
/// The filesystem path of one event. `/` on both sides is accepted so
/// callers can join with either separator; only the name's own content
/// decides the file.
fn path_of(root : String, name : String) -> String {
  let base = if root.length() > 0 && root[root.length() - 1] == '/' {
    root[0:root.length() - 1]
  } else {
    root
  }
  "\{base}/\{name}"
}

///|
/// Refuse any name that is not one plain file-name token: letters,
/// digits, `.`, `_`, `-` only, and it must not begin with a dot. This
/// keeps a client-supplied path (`..`, absolute paths, separators,
/// Windows drive letters) from ever reaching the filesystem — the
/// name that arrives over HTTP is data, not a path.
fn check_name(name : String) -> Unit raise {
  let ok = name.length() > 0 && name[0] != '.'
  if ok {
    for c in name.to_array() {
      let code = c.to_int()
      let letter = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
        (code >= 'A'.to_int() && code <= 'Z'.to_int())
      let digit = code >= '0'.to_int() && code <= '9'.to_int()
      if !(letter || digit || c == '.' || c == '_' || c == '-') {
        raise StoreError::BadName(name~)
      }
    }
  } else {
    raise StoreError::BadName(name~)
  }
}
