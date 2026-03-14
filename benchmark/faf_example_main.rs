#![allow(clippy::missing_safety_doc, unused_imports, dead_code)]

#[inline(always)]
fn likely(b: bool) -> bool { b }
use faf::epoll;
use faf::util::memcmp;

const METHOD_GET: &[u8] = b"GET";
const METHOD_GET_LEN: usize = METHOD_GET.len();
const ROUTE_PLAINTEXT: &[u8] = b"/plaintext";
const ROUTE_PLAINTEXT_LEN: usize = ROUTE_PLAINTEXT.len();

const DATE_LEN: usize = 35;
const PLAINTEXT_PREFIX: &str = concat!(
    "HTTP/1.1 200 OK\r\n",
    "Server: F\r\n",
    "Content-Type: text/plain\r\n",
    "Content-Length: 13\r\n",
    "Connection: keep-alive\r\n"
);
const PLAINTEXT_SUFFIX: &str = "\r\n\r\nHello, World!";

#[inline(always)]
fn cb(
    method: *const u8,
    method_len: usize,
    path: *const u8,
    path_len: usize,
    response_buffer: *mut u8,
    date_buff: *const u8,
) -> usize {
    unsafe {
        if likely(method_len == METHOD_GET_LEN && path_len == ROUTE_PLAINTEXT_LEN) &&
            likely(memcmp(METHOD_GET.as_ptr(), method, METHOD_GET_LEN) == 0) &&
            likely(memcmp(ROUTE_PLAINTEXT.as_ptr(), path, ROUTE_PLAINTEXT_LEN) == 0)
        {
            let prefix = PLAINTEXT_PREFIX.as_bytes();
            let suffix = PLAINTEXT_SUFFIX.as_bytes();
            core::ptr::copy_nonoverlapping(prefix.as_ptr(), response_buffer, prefix.len());
            core::ptr::copy_nonoverlapping(date_buff, response_buffer.add(prefix.len()), DATE_LEN);
            core::ptr::copy_nonoverlapping(
                suffix.as_ptr(),
                response_buffer.add(prefix.len() + DATE_LEN),
                suffix.len(),
            );
            prefix.len() + DATE_LEN + suffix.len()
        } else {
            0
        }
    }
}

#[inline(always)]
pub fn main() {
    epoll::go(8080, cb);
}
