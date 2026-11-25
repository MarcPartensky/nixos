//! RFC 6455 framing, both directions.
//!
//! The server never masks (section 5.1), a client always does, and a message
//! may be split over several frames: `Framer` owns the buffer and the partial
//! message, so a short read simply means "call me again with more bytes".

use crate::MAX_MESSAGE;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Op {
    Text,
    Binary,
    Close,
    Ping,
    Pong,
    Other(u8),
}

impl Op {
    pub fn from_code(code: u8) -> Self {
        match code & 0x0f {
            0x1 => Op::Text,
            0x2 => Op::Binary,
            0x8 => Op::Close,
            0x9 => Op::Ping,
            0xA => Op::Pong,
            other => Op::Other(other),
        }
    }

    pub fn code(self) -> u8 {
        match self {
            Op::Text => 0x1,
            Op::Binary => 0x2,
            Op::Close => 0x8,
            Op::Ping => 0x9,
            Op::Pong => 0xA,
            Op::Other(other) => other,
        }
    }

    pub fn is_control(self) -> bool {
        matches!(self, Op::Close | Op::Ping | Op::Pong)
    }
}

fn header(first: u8, len: usize, mask: Option<[u8; 4]>) -> Vec<u8> {
    let mut out = Vec::with_capacity(14);
    out.push(first);
    let mask_bit = if mask.is_some() { 0x80 } else { 0 };
    if len < 126 {
        out.push(mask_bit | len as u8);
    } else if len < 65536 {
        out.push(mask_bit | 126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(mask_bit | 127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
    out
}

/// Server -> client frame: unmasked.
pub fn encode(payload: &[u8], opcode: u8) -> Vec<u8> {
    let mut out = header(0x80 | (opcode & 0x0f), payload.len(), None);
    out.extend_from_slice(payload);
    out
}

/// Client -> server frame: masked, as the RFC demands.
pub fn encode_masked(payload: &[u8], opcode: u8, mask: [u8; 4]) -> Vec<u8> {
    let mut out = header(0x80 | (opcode & 0x0f), payload.len(), Some(mask));
    out.extend_from_slice(&mask);
    out.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out
}

#[derive(Debug, Default)]
pub struct Framer {
    buf: Vec<u8>,
    partial: Option<(u8, Vec<u8>)>,
}

impl Framer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    pub fn buffered(&self) -> usize {
        self.buf.len()
    }

    /// Next complete message, or `None` when the bytes on hand end mid-frame.
    pub fn next_message(&mut self) -> Result<Option<(Op, Vec<u8>)>, String> {
        loop {
            let Some((fin, opcode, payload)) = self.take_frame()? else {
                return Ok(None);
            };
            let op = Op::from_code(opcode);
            if op.is_control() {
                return Ok(Some((op, payload)));
            }
            if let Some((_, acc)) = self.partial.as_mut() {
                acc.extend_from_slice(&payload);
                if acc.len() > MAX_MESSAGE {
                    return Err("message too large".to_string());
                }
                if fin {
                    let (first, whole) = self.partial.take().unwrap_or((opcode, Vec::new()));
                    return Ok(Some((Op::from_code(first), whole)));
                }
                continue;
            }
            if fin {
                return Ok(Some((op, payload)));
            }
            self.partial = Some((opcode, payload));
        }
    }

    fn take_frame(&mut self) -> Result<Option<(bool, u8, Vec<u8>)>, String> {
        if self.buf.len() < 2 {
            return Ok(None);
        }
        let fin = self.buf[0] & 0x80 != 0;
        let opcode = self.buf[0] & 0x0f;
        let masked = self.buf[1] & 0x80 != 0;
        let mut len = (self.buf[1] & 0x7f) as usize;
        let mut offset = 2;

        if len == 126 {
            if self.buf.len() < 4 {
                return Ok(None);
            }
            len = u16::from_be_bytes([self.buf[2], self.buf[3]]) as usize;
            offset = 4;
        } else if len == 127 {
            if self.buf.len() < 10 {
                return Ok(None);
            }
            let mut wide = 0u64;
            for byte in &self.buf[2..10] {
                wide = (wide << 8) | *byte as u64;
            }
            len = wide as usize;
            offset = 10;
        }

        if len > MAX_MESSAGE {
            return Err("frame too large".to_string());
        }

        let mask_start = offset;
        if masked {
            offset += 4;
        }
        if self.buf.len() < offset + len {
            return Ok(None);
        }

        let mut payload = self.buf[offset..offset + len].to_vec();
        if masked {
            let mask = [
                self.buf[mask_start],
                self.buf[mask_start + 1],
                self.buf[mask_start + 2],
                self.buf[mask_start + 3],
            ];
            for (i, byte) in payload.iter_mut().enumerate() {
                *byte ^= mask[i % 4];
            }
        }

        self.buf.drain(..offset + len);
        Ok(Some((fin, opcode, payload)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_frame_round_trips_through_a_server_side_framer() {
        let framed = encode(b"hello", 0x1);
        let mut framer = Framer::new();
        framer.push(&framed);
        let (op, payload) = framer.next_message().unwrap().unwrap();
        assert_eq!(op, Op::Text);
        assert_eq!(payload, b"hello");
        assert_eq!(framer.next_message().unwrap(), None);
    }

    #[test]
    fn client_frames_are_demasked() {
        let mask = [1u8, 2, 3, 4];
        let framed = encode_masked(b"{\"t\":\"leave\"}", 0x1, mask);
        let mut framer = Framer::new();
        framer.push(&framed);
        let (op, payload) = framer.next_message().unwrap().unwrap();
        assert_eq!(op, Op::Text);
        assert_eq!(payload, b"{\"t\":\"leave\"}");
    }

    #[test]
    fn partial_frames_wait_for_the_rest() {
        let framed = encode_masked(&[b'x'; 300], 0x1, [9, 9, 9, 9]);
        let mut framer = Framer::new();
        framer.push(&framed[..7]);
        assert_eq!(framer.next_message().unwrap(), None);
        framer.push(&framed[7..]);
        let (_, payload) = framer.next_message().unwrap().unwrap();
        assert_eq!(payload.len(), 300);
    }

    #[test]
    fn two_frames_in_one_read_are_both_returned() {
        let mut bytes = encode(b"one", 0x1);
        bytes.extend_from_slice(&encode(b"two", 0x1));
        let mut framer = Framer::new();
        framer.push(&bytes);
        assert_eq!(framer.next_message().unwrap().unwrap().1, b"one");
        assert_eq!(framer.next_message().unwrap().unwrap().1, b"two");
        assert_eq!(framer.next_message().unwrap(), None);
    }
}
