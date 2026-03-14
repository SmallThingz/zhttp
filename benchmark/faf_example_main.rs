#![allow(clippy::missing_safety_doc, unused_imports, dead_code)]

#[inline(always)]
fn likely(b: bool) -> bool { b }
use faf::epoll;
use faf::util::memcmp;
use core::ptr::read_unaligned;

const PLAINTEXT_RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\n\
    Server: F\r\n\
    Content-Type: text/plain\r\n\
    Content-Length: 13\r\n\
    Connection: keep-alive\r\n\
    Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n\
    \r\n\
    Hello, World!";

const RESPONSE_LEN: usize = PLAINTEXT_RESPONSE.len();

#[inline(always)]
fn cb(
    _method: *const u8,
    _method_len: usize,
    _path: *const u8,
    _path_len: usize,
    response_buffer: *mut u8,
    _date_buff: *const u8,
) -> usize {
    unsafe {
    core::ptr::copy_nonoverlapping(PLAINTEXT_RESPONSE.as_ptr(), response_buffer, RESPONSE_LEN);
    RESPONSE_LEN
    }
}

#[inline(always)]
pub fn main() {
    epoll::go(8080, cb);
}
