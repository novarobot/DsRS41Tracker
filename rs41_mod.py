#!/usr/bin/env python3
"""RS41-only WAV/PCM stream demodulator with RS(255,231) correction.

Implements only the project pipeline corresponding to:
    rs41mod -r -i -vv /dev/stdin

Input: RIFF/WAVE PCM on stdin, 48 kHz, mono (first channel), 8/16-bit.
Output: 320-byte dewhitened RS41 frames as lowercase hex plus status.

Compared with the first prototype this version does not quantize the entire
recording with one fixed phase. It finds every RS41 header directly in the
sample stream with a Gaussian matched template, then decodes that frame using
its own local symbol phase. This mirrors the important acquisition behaviour
of demod_mod.c much more closely.
"""

import math
import struct
import sys
from dataclasses import dataclass
from typing import BinaryIO, Iterator, Optional

import numpy as np

SAMPLE_RATE = 48_000
BAUD_RATE = 4_800
SPS = SAMPLE_RATE / BAUD_RATE
FRAME_LEN = 320
FRAME_BITS = FRAME_LEN * 8
HEADER_TEXT = "0000100001101101010100111000100001000100011010010100100000011111"
HEADER_BITS = np.fromiter((int(c) for c in HEADER_TEXT), dtype=np.uint8)
HEADER_BYTES = bytes.fromhex("8635f44093df1a60")
HEADER_SAMPLES = int(round(len(HEADER_BITS) * SPS))
PAYLOAD_BITS = (FRAME_LEN - len(HEADER_BYTES)) * 8
BIT_OFFSET = 2                 # rs41mod default bitofs
HEADER_THRESHOLD = 0.57       # normalized matched-filter threshold
MIN_HEADER_DISTANCE = 20_000  # samples; suppress duplicate peaks
KEEP_SAMPLES = 80_000         # enough for a whole frame plus overlap

MASK = bytes.fromhex(
    "96833e51b14908983205590ef944c6262160c2ea795d6da15469470cdce85cf1"
    "f776827f0799a22c937c3063f5102e61d0bcb4b606aaf423786e3baebf7b4cc1"
)


# Exact pure-Python port of the RS(255,231) path used by bch_ecc_mod.c.
MAX_DEG=254
N=255; T=12; R=24; K=231; B=0

EXP=[0]*256; LOG=[0]*256
x=1
for i in range(256):
    EXP[i]=x
    x <<= 1
    if x & 0x100: x ^= 0x11D
    x &= 0xFF
for i in range(1,256): LOG[EXP[i]]=i

def mul(a,b):
    if not a or not b:return 0
    return EXP[(LOG[a]+LOG[b])%255]
def inv(a):
    return 0 if not a else EXP[255-LOG[a]]
def deg(p):
    n=len(p)-1
    while n>=0 and p[n]==0:n-=1
    return n
def peval(p,x):
    y=p[0]
    if x:
      lx=LOG[x]
      for n in range(1,min(len(p),255)):
        if p[n]: y ^= mul(p[n],EXP[(n*lx)%255])
    return y
def pmul(a,b):
    da,db=deg(a),deg(b)
    c=[0]*255
    if da<0 or db<0:return c
    for i in range(da+1):
      if a[i]:
       for j in range(db+1):
        if b[j]: c[i+j]^=mul(a[i],b[j])
    return c
def pdiv(p,q):
    dp,dq=deg(p),deg(q)
    d=[0]*255;r=[0]*255
    if dq<0: raise ZeroDivisionError
    if dp<0:return d,r
    if dq==0:
      c=mul(p[dp],inv(q[dq]))
      for i in range(dp+1):d[i]=mul(p[i],c)
      return d,r
    if dp<dq:
      r[:dp+1]=p[:dp+1];return d,r
    r[:dp+1]=p[:dp+1]
    c=mul(p[dp],inv(q[dq]))
    while dp>=dq:
      d[dp-dq]=c
      for i in range(dq+1): r[dp-i]^=mul(q[dq-i],c)
      while dp>=0 and r[dp]==0:dp-=1
      if dp>=dq:c=mul(r[dp],inv(q[dq]))
    return d,r
def lfsr(degstop,x2t,S):
    r0=S[:]; r1=[0]*255;r1[x2t]=1
    s0=[0]*255;s0[0]=1;s1=[0]*255
    while deg(r1)>=degstop:
      quo,r2=pdiv(r0,r1)
      r0,r1=r1,r2
      s2=[a^b for a,b in zip(s0,pmul(quo,s1))]
      s0,s1=s1,s2
    return s1,r1
def deriv(a):
    d=[0]*255
    for i in range(1,deg(a)+1,2):d[i-1]=a[i]
    return d
def forney(x,Omega,Lambda):
    w=peval(Omega,x); z=peval(deriv(Lambda),x)
    if z==0:return 0
    y=mul(w,inv(z))
    y=mul(inv(x),y) # b=0
    return y

def decode(cw):
    cw=list(cw)
    S=[0]*255; bad=False
    for i in range(24):
      S[i]=peval(cw,EXP[i])
      bad |= bool(S[i])
    if not bad:return cw,0
    Lam,Om=lfsr(12,24,S)
    dl,do=deg(Lam),deg(Om)
    if do>=dl:return cw,-3
    gamma=Lam[0]
    if not gamma:return cw,-2
    gi=inv(gamma)
    for i in range(dl+1):Lam[i]=mul(Lam[i],gi)
    for i in range(do+1):Om[i]=mul(Om[i],gi)
    dsl=deg(Lam)
    pos=[];val=[]
    for i in range(1,256):
      if peval(Lam,i)==0:
        x1=inv(i); pos.append(LOG[x1]%255); val.append(forney(i,Om,Lam))
        if len(pos)>=dsl:break
    if len(pos)<dsl:return cw,-1
    for p,v in zip(pos,val):cw[p]^=v
    # verify
    for i in range(24):
      if peval(cw,EXP[i]): return cw,-1
    return cw,len(pos)


def rs41_ecc(frame: bytes) -> tuple[bytes, int, int]:
	if len(frame) not in (320, 518):
		return frame, -1, -1
	original_len = len(frame)
	f = bytearray(518)
	f[:original_len] = frame
	cw1 = bytearray(255)
	cw2 = bytearray(255)
	cw1[:24] = f[8:32]
	cw2[:24] = f[32:56]
	for i in range(231):
		cw1[24 + i] = f[56 + 2 * i]
		cw2[24 + i] = f[57 + 2 * i]
	c1, e1 = decode(cw1)
	c2, e2 = decode(cw2)
	for i in range(24):
		f[8 + i] = c1[i]
		f[32 + i] = c2[i]
	for i in range(231):
		f[56 + 2 * i] = c1[24 + i]
		f[57 + 2 * i] = c2[24 + i]
	return bytes(f[:original_len]), e1, e2


@dataclass
class WaveFormat:
    channels: int
    rate: int
    bits: int


def read_exact(fp: BinaryIO, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        part = fp.read(size - len(data))
        if not part:
            raise EOFError("unexpected end of input")
        data.extend(part)
    return bytes(data)


def read_wave_header(fp: BinaryIO) -> WaveFormat:
    header = read_exact(fp, 12)
    if header[:4] != b"RIFF" or header[8:12] != b"WAVE":
        raise ValueError("stdin is not a RIFF/WAVE stream")

    fmt: Optional[WaveFormat] = None
    while True:
        chunk_id = read_exact(fp, 4)
        chunk_len = struct.unpack("<I", read_exact(fp, 4))[0]
        if chunk_id == b"fmt ":
            body = read_exact(fp, chunk_len)
            if len(body) < 16:
                raise ValueError("invalid WAVE fmt chunk")
            encoding, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if encoding != 1:
                raise ValueError("only integer PCM WAVE is supported")
            fmt = WaveFormat(channels, rate, bits)
        elif chunk_id == b"data":
            if fmt is None:
                raise ValueError("WAVE data chunk precedes fmt chunk")
            return fmt
        else:
            read_exact(fp, chunk_len)
        if chunk_len & 1:
            read_exact(fp, 1)


def pcm_blocks(fp: BinaryIO, fmt: WaveFormat, frames_per_block: int = 48_000) -> Iterator[np.ndarray]:
    if fmt.rate != SAMPLE_RATE:
        raise ValueError(f"expected {SAMPLE_RATE} Hz, got {fmt.rate} Hz")
    if fmt.channels < 1:
        raise ValueError("invalid channel count")
    if fmt.bits not in (8, 16):
        raise ValueError("only 8-bit or 16-bit PCM is supported")

    bytes_per_sample = fmt.bits // 8
    frame_size = fmt.channels * bytes_per_sample
    carry = b""
    while True:
        raw = fp.read(frames_per_block * frame_size)
        if not raw:
            break
        raw = carry + raw
        usable = len(raw) - len(raw) % frame_size
        carry = raw[usable:]
        raw = raw[:usable]
        if not raw:
            continue
        if fmt.bits == 16:
            samples = np.frombuffer(raw, dtype="<i2").astype(np.float32)
            scale = 32768.0
        else:
            samples = np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0
            scale = 128.0
        if fmt.channels > 1:
            samples = samples.reshape(-1, fmt.channels)[:, 0]
        yield samples / scale


def gaussian_header_template() -> np.ndarray:
    # Same GFSK pulse construction used by init_buffers() in demod_mod.c.
    bt = 0.5
    sigma = math.sqrt(math.log(2.0)) / (2.0 * math.pi * bt)

    def q(x: np.ndarray) -> np.ndarray:
        # NumPy has no guaranteed erf in all builds; scalar math.erf is fine here.
        return 0.5 - 0.5 * np.fromiter((math.erf(float(v) / math.sqrt(2.0)) for v in x), dtype=np.float64)

    def pulse(t: np.ndarray) -> np.ndarray:
        return q((t - 0.5) / sigma) - q((t + 0.5) / sigma)

    out = np.zeros(HEADER_SAMPLES, dtype=np.float64)
    for i in range(HEADER_SAMPLES):
        pos = int(i / SPS)
        t = (i - pos * SPS) / SPS - 0.5
        b = (2.0 * HEADER_BITS[pos] - 1.0) * pulse(np.array([t]))[0]
        if pos > 0:
            b += (2.0 * HEADER_BITS[pos - 1] - 1.0) * pulse(np.array([t + 1.0]))[0]
        if pos + 1 < len(HEADER_BITS):
            b += (2.0 * HEADER_BITS[pos + 1] - 1.0) * pulse(np.array([t - 1.0]))[0]
        out[i] = b
    norm = np.linalg.norm(out)
    return (out / norm).astype(np.float32)


HEADER_TEMPLATE = gaussian_header_template()
HEADER_TEMPLATE_ENERGY = float(np.dot(HEADER_TEMPLATE, HEADER_TEMPLATE))


def bits_to_byte(bits: np.ndarray) -> int:
    value = 0
    for bit_index, bit in enumerate(bits):
        value |= int(bit) << bit_index
    return value


def crc16(data: bytes) -> int:
    rem = 0xFFFF
    for byte in data:
        rem ^= byte << 8
        for _ in range(8):
            rem = ((rem << 1) ^ 0x1021) & 0xFFFF if rem & 0x8000 else (rem << 1) & 0xFFFF
    return rem


def packet_crc_ok(frame: bytes, pos: int, expected_type: Optional[int]) -> bool:
    if pos + 4 > len(frame):
        return False
    ptype = frame[pos]
    length = frame[pos + 1]
    if expected_type is not None and ptype != expected_type:
        return False
    end = pos + length + 4
    if end > len(frame):
        return False
    stored = frame[pos + 2 + length] | frame[pos + 3 + length] << 8
    return stored == crc16(frame[pos + 2:pos + 2 + length])


def valid_packet_count(frame: bytes) -> int:
    checks = ((0x039, 0x79), (0x065, 0x7A), (0x093, 0x7C),
              (0x0B5, 0x7D), (0x112, 0x7B), (0x12B, None))
    return sum(packet_crc_ok(frame, pos, ptype) for pos, ptype in checks)


def normalized_correlation(samples: np.ndarray, template: np.ndarray) -> np.ndarray:
    if len(samples) < len(template):
        return np.empty(0, dtype=np.float32)
    corr = np.correlate(samples, template, mode="valid")
    sq = samples.astype(np.float64) ** 2
    cs = np.concatenate(([0.0], np.cumsum(sq)))
    energy = cs[len(template):] - cs[:-len(template)]
    denom = np.sqrt(np.maximum(energy * HEADER_TEMPLATE_ENERGY, 1e-20))
    return (corr / denom).astype(np.float32)


class Demodulator:
    def __init__(self) -> None:
        self.samples = np.empty(0, dtype=np.float32)
        self.absolute_base = 0
        self.search_from = 0
        self.last_header_abs = -MIN_HEADER_DISTANCE
        self.last_ecc = (-1, -1)

    def add_samples(self, block: np.ndarray, final: bool = False) -> Iterator[bytes]:
        self.samples = np.concatenate((self.samples, block))
        needed_after_header = int(math.ceil(FRAME_BITS * SPS)) + BIT_OFFSET + 4

        while True:
            scan_end = len(self.samples) - needed_after_header
            if scan_end <= self.search_from:
                break

            region_start = max(0, self.search_from)
            region_stop = scan_end + HEADER_SAMPLES
            region = self.samples[region_start:region_stop]
            scores = normalized_correlation(region, HEADER_TEMPLATE)
            if not len(scores):
                break

            # Search both polarities; project input uses inverted audio.
            abs_scores = np.abs(scores)
            candidates = np.flatnonzero(abs_scores >= HEADER_THRESHOLD)
            if not len(candidates):
                self.search_from = scan_end
                break

            # Use the strongest peak in the first local peak cluster.
            first = int(candidates[0])
            cluster = candidates[candidates <= first + int(2 * SPS)]
            rel_peak = int(cluster[np.argmax(abs_scores[cluster])])
            header_start = region_start + rel_peak
            header_abs = self.absolute_base + header_start

            if header_abs - self.last_header_abs < MIN_HEADER_DISTANCE:
                self.search_from = header_start + int(SPS)
                continue

            polarity = 1.0 if scores[rel_peak] >= 0.0 else -1.0
            frame = self._decode_frame(header_start, polarity)
            if frame is None:
                break

            self.last_header_abs = header_abs
            self.search_from = header_start + int(0.75 * SAMPLE_RATE)
            yield frame

        # Keep enough overlap for the next call, but never discard an undecoded candidate.
        safe_drop = min(self.search_from, max(0, len(self.samples) - KEEP_SAMPLES))
        if safe_drop > 0:
            self.samples = self.samples[safe_drop:]
            self.absolute_base += safe_drop
            self.search_from -= safe_drop

    def _decode_frame(self, header_start: int, polarity: float) -> Optional[bytes]:
        """Decode one frame using an affine symbol clock.

        The correlation maximum is not guaranteed to coincide with the exact
        end of the 64-bit header.  Search a wider origin range and a small
        samples-per-symbol range.  All symbol integrals are calculated from a
        cumulative sum, so a candidate costs only vector indexing rather than
        thousands of Python-level summations.
        """
        nominal_origin = header_start + HEADER_SAMPLES + BIT_OFFSET

        # Enough data for the slowest clock and the largest positive offset.
        max_sps = SPS + 0.035
        required_end = nominal_origin + 14 + int(math.ceil(PAYLOAD_BITS * max_sps)) + 3
        if required_end > len(self.samples):
            return None

        # Local cumulative sum makes all symbol integrations vectorized.
        local_start = max(0, nominal_origin - 16)
        local_end = required_end
        x = (polarity * self.samples[local_start:local_end]).astype(np.float64)
        cs = np.empty(len(x) + 1, dtype=np.float64)
        cs[0] = 0.0
        np.cumsum(x, out=cs[1:])

        best_frame: Optional[bytes] = None
        best_key = (-1, -1, -1.0)
        raw_candidates: list[tuple[tuple[int, int, float], bytes]] = []

        # First search the exact 10.0 sps clock over a wide phase interval.
        # Then refine clock rate only around the best phases.
        phase_results = []
        bit_numbers = np.arange(PAYLOAD_BITS + 1, dtype=np.float64)

        for shift in range(-14, 15):
            origin = nominal_origin + shift - local_start
            edges = np.rint(origin + bit_numbers * SPS).astype(np.int64)
            if edges[0] < 0 or edges[-1] >= len(cs):
                continue
            soft = cs[edges[1:]] - cs[edges[:-1]]
            candidate = self._bits_to_frame(soft >= 0.0)
            packets = valid_packet_count(candidate)
            header = int(candidate.startswith(HEADER_BYTES))
            strength = float(np.mean(np.abs(soft)))
            phase_results.append((packets, header, strength, shift))
            key = (packets, header, strength)
            raw_candidates.append((key, candidate))
            if key > best_key:
                best_key = key
                best_frame = candidate

        # Refine the three best phase candidates with a small clock-rate grid.
        phase_results.sort(reverse=True)
        for _, _, _, shift in phase_results[:3]:
            for delta in (-0.030, -0.020, -0.010, -0.005, 0.005, 0.010, 0.020, 0.030):
                trial_sps = SPS + delta
                origin = nominal_origin + shift - local_start
                edges = np.rint(origin + bit_numbers * trial_sps).astype(np.int64)
                if edges[0] < 0 or edges[-1] >= len(cs):
                    continue
                soft = cs[edges[1:]] - cs[edges[:-1]]
                candidate = self._bits_to_frame(soft >= 0.0)
                packets = valid_packet_count(candidate)
                header = int(candidate.startswith(HEADER_BYTES))
                strength = float(np.mean(np.abs(soft)))
                key = (packets, header, strength)
                raw_candidates.append((key, candidate))
                if key > best_key:
                    best_key = key
                    best_frame = candidate
                    if packets == 6:
                        self.last_ecc = (0, 0)
                        return best_frame

        # Reed-Solomon is intentionally evaluated only for the strongest raw
        # candidates. Running it inside the complete timing grid would be slow.
        corrected_best = best_frame
        corrected_status = (-1, -1)
        corrected_key = (-1, -1, -1, -1.0)
        seen = set()
        for raw_key, raw_frame in sorted(raw_candidates, reverse=True)[:8]:
            if raw_frame in seen:
                continue
            seen.add(raw_frame)
            corrected, e1, e2 = rs41_ecc(raw_frame)
            packets = valid_packet_count(corrected)
            both_ok = int(e1 >= 0 and e2 >= 0)
            corrected_count = (e1 if e1 > 0 else 0) + (e2 if e2 > 0 else 0)
            key = (packets, both_ok, -corrected_count, raw_key[2])
            if key > corrected_key:
                corrected_key = key
                corrected_best = corrected
                corrected_status = (e1, e2)
                if packets == 6 and both_ok:
                    break

        self.last_ecc = corrected_status
        return corrected_best

    @staticmethod
    def _bits_to_frame(bits: np.ndarray) -> bytes:
        # Pack LSB-first bits without a Python loop per bit.
        payload = bits[:PAYLOAD_BITS].reshape(-1, 8).astype(np.uint16)
        weights = (1 << np.arange(8, dtype=np.uint16))
        raw = np.sum(payload * weights, axis=1).astype(np.uint8)

        frame = bytearray(HEADER_BYTES)
        for byte_index, value in enumerate(raw, start=8):
            frame.append(int(value) ^ MASK[byte_index % len(MASK)])
        return bytes(frame)


def main() -> int:
    try:
        fmt = read_wave_header(sys.stdin.buffer)
        demod = Demodulator()
        for block in pcm_blocks(sys.stdin.buffer, fmt):
            for frame in demod.add_samples(block):
                e1, e2 = demod.last_ecc
                if e1 >= 0 and e2 >= 0:
                    print(frame.hex(), f"[OK] ({max(e1, 0) + max(e2, 0)})", flush=True)
                else:
                    marks = ("+" if e1 >= 0 else "-") + ("+" if e2 >= 0 else "-")
                    print(frame.hex(), f"[NO] ({marks})", flush=True)
        for frame in demod.add_samples(np.empty(0, dtype=np.float32), final=True):
            clean = frame.startswith(HEADER_BYTES) and valid_packet_count(frame) == 6
            print(frame.hex(), "[OK] (0)" if clean else "[NO] (--)", flush=True)
        return 0
    except BrokenPipeError:
        return 0
    except Exception as exc:
        print(f"rs41_mod_v4.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
