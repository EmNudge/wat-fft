;; Radix-4 split-format Stockham FFT probe (Experiment 58)
;;
;; Supports n = 4^p only (16, 64, 256, 1024, 4096).
;; Split planes: separate re/im arrays. All generic-stage SIMD ops are
;; shuffle-free (the -i rotation is an operand swap + negate in split form).
;; Twiddle tables are precomputed by the JS harness, laid out per stage as
;; six consecutive f32 arrays of length l: w1re, w1im, w2re, w2im, w3re, w3im.
;;
;; Memory layout (bytes):
;;   SRC_RE = 0        SRC_IM = 65536
;;   DST_RE = 131072   DST_IM = 196608
;;   TW     = 262144
(module
  (memory (export "memory") 8)

  (global $SRC_RE i32 (i32.const 0))
  (global $SRC_IM i32 (i32.const 65536))
  (global $DST_RE i32 (i32.const 131072))
  (global $DST_IM i32 (i32.const 196608))
  (global $TW i32 (i32.const 262144))

  ;; Generic radix-4 stage for s >= 4 (s = elements per quarter-group).
  ;; One twiddle triple per group j, splatted; inner loop is 4-wide over t.
  (func $stage_generic
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $s i32) (param $l i32) (param $tw i32) (param $n i32)

    (local $j i32)
    (local $tb i32)
    (local $s_bytes i32)
    (local $n4b i32)
    (local $in0 i32)
    (local $q i32)
    (local $lb i32)

    (local $w1r v128) (local $w1i v128)
    (local $w2r v128) (local $w2i v128)
    (local $w3r v128) (local $w3i v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $wcr v128) (local $wci v128)
    (local $wbr v128) (local $wbi v128)
    (local $wdr v128) (local $wdi v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $s_bytes (i32.shl (local.get $s) (i32.const 2)))
    (local.set $n4b (local.get $n))  ;; (n/4 elements) * 4 bytes = n bytes
    (local.set $lb (i32.shl (local.get $l) (i32.const 2)))  ;; l * 4 bytes

    (local.set $j (i32.const 0))
    (block $done_groups
      (loop $group_loop
        (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

        ;; Splat the 6 twiddle scalars for group j
        ;; layout: w1re[l] w1im[l] w2re[l] w2im[l] w3re[l] w3im[l]
        (local.set $in0 (i32.add (local.get $tw) (i32.shl (local.get $j) (i32.const 2))))
        (local.set $w1r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w1i (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w2r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w2i (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w3r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w3i (f32x4.splat (f32.load (local.get $in0))))

        (local.set $tb (i32.const 0))
        (block $done_t
          (loop $t_loop
            (br_if $done_t (i32.ge_u (local.get $tb) (local.get $s_bytes)))

            ;; in0 = base + tb, base = j * 4*s_bytes
            (local.set $in0 (i32.add
              (i32.mul (local.get $j) (i32.shl (local.get $s_bytes) (i32.const 2)))
              (local.get $tb)))

            (local.set $ar (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $ai (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $br (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $bi (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $cr (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $ci (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $dr (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $di (v128.load (i32.add (local.get $src_im) (local.get $in0))))

            ;; wc = w2 * c, wb = w1 * b, wd = w3 * d  (split-form cmul, no shuffles)
            (local.set $wcr (f32x4.sub (f32x4.mul (local.get $w2r) (local.get $cr))
                                       (f32x4.mul (local.get $w2i) (local.get $ci))))
            (local.set $wci (f32x4.add (f32x4.mul (local.get $w2r) (local.get $ci))
                                       (f32x4.mul (local.get $w2i) (local.get $cr))))
            (local.set $wbr (f32x4.sub (f32x4.mul (local.get $w1r) (local.get $br))
                                       (f32x4.mul (local.get $w1i) (local.get $bi))))
            (local.set $wbi (f32x4.add (f32x4.mul (local.get $w1r) (local.get $bi))
                                       (f32x4.mul (local.get $w1i) (local.get $br))))
            (local.set $wdr (f32x4.sub (f32x4.mul (local.get $w3r) (local.get $dr))
                                       (f32x4.mul (local.get $w3i) (local.get $di))))
            (local.set $wdi (f32x4.add (f32x4.mul (local.get $w3r) (local.get $di))
                                       (f32x4.mul (local.get $w3i) (local.get $dr))))

            (local.set $t0r (f32x4.add (local.get $ar) (local.get $wcr)))
            (local.set $t0i (f32x4.add (local.get $ai) (local.get $wci)))
            (local.set $t1r (f32x4.sub (local.get $ar) (local.get $wcr)))
            (local.set $t1i (f32x4.sub (local.get $ai) (local.get $wci)))
            (local.set $t2r (f32x4.add (local.get $wbr) (local.get $wdr)))
            (local.set $t2i (f32x4.add (local.get $wbi) (local.get $wdi)))
            (local.set $t3r (f32x4.sub (local.get $wbr) (local.get $wdr)))
            (local.set $t3i (f32x4.sub (local.get $wbi) (local.get $wdi)))

            ;; q = j*s_bytes + tb
            (local.set $q (i32.add (i32.mul (local.get $j) (local.get $s_bytes)) (local.get $tb)))

            (v128.store (i32.add (local.get $dst_re) (local.get $q))
              (f32x4.add (local.get $t0r) (local.get $t2r)))
            (v128.store (i32.add (local.get $dst_im) (local.get $q))
              (f32x4.add (local.get $t0i) (local.get $t2i)))

            (local.set $q (i32.add (local.get $q) (local.get $n4b)))
            ;; -i * t3 = (t3i, -t3r)
            (v128.store (i32.add (local.get $dst_re) (local.get $q))
              (f32x4.add (local.get $t1r) (local.get $t3i)))
            (v128.store (i32.add (local.get $dst_im) (local.get $q))
              (f32x4.sub (local.get $t1i) (local.get $t3r)))

            (local.set $q (i32.add (local.get $q) (local.get $n4b)))
            (v128.store (i32.add (local.get $dst_re) (local.get $q))
              (f32x4.sub (local.get $t0r) (local.get $t2r)))
            (v128.store (i32.add (local.get $dst_im) (local.get $q))
              (f32x4.sub (local.get $t0i) (local.get $t2i)))

            (local.set $q (i32.add (local.get $q) (local.get $n4b)))
            (v128.store (i32.add (local.get $dst_re) (local.get $q))
              (f32x4.sub (local.get $t1r) (local.get $t3i)))
            (v128.store (i32.add (local.get $dst_im) (local.get $q))
              (f32x4.add (local.get $t1i) (local.get $t3r)))

            (local.set $tb (i32.add (local.get $tb) (i32.const 16)))
            (br $t_loop)
          )
        )

        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $group_loop)
      )
    )
  )

  ;; Final s=1 stage: 4 groups per iteration with 4 DIFFERENT twiddle triples.
  ;; Group j inputs are src[4j..4j+3]; a 4x4 transpose gathers a/b/c/d vectors.
  (func $stage_s1
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $l i32) (param $tw i32) (param $n i32)

    (local $j i32)
    (local $n4b i32)
    (local $lb i32)
    (local $p i32)
    (local $q i32)

    (local $v0 v128) (local $v1 v128) (local $v2 v128) (local $v3 v128)
    (local $p0 v128) (local $p1 v128) (local $p2 v128) (local $p3 v128)
    (local $w1r v128) (local $w1i v128)
    (local $w2r v128) (local $w2i v128)
    (local $w3r v128) (local $w3i v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $wcr v128) (local $wci v128)
    (local $wbr v128) (local $wbi v128)
    (local $wdr v128) (local $wdi v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $n4b (local.get $n))
    (local.set $lb (i32.shl (local.get $l) (i32.const 2)))

    (local.set $j (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $j) (local.get $l)))

        ;; ---- real plane: load 16 consecutive floats, transpose 4x4 ----
        (local.set $p (i32.add (local.get $src_re) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        ;; p0 = [a0,a1,c0,c1], p2 = [b0,b1,d0,d1] (from v0,v1)
        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        ;; p1 = [a2,a3,c2,c3], p3 = [b2,b3,d2,d3] (from v2,v3)
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ar (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $cr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $br (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $dr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- imag plane ----
        (local.set $p (i32.add (local.get $src_im) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ai (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $ci (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $bi (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $di (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- 4 consecutive twiddle triples ----
        (local.set $p (i32.add (local.get $tw) (i32.shl (local.get $j) (i32.const 2))))
        (local.set $w1r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w1i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3i (v128.load (local.get $p)))

        ;; ---- same butterfly math as generic stage ----
        (local.set $wcr (f32x4.sub (f32x4.mul (local.get $w2r) (local.get $cr))
                                   (f32x4.mul (local.get $w2i) (local.get $ci))))
        (local.set $wci (f32x4.add (f32x4.mul (local.get $w2r) (local.get $ci))
                                   (f32x4.mul (local.get $w2i) (local.get $cr))))
        (local.set $wbr (f32x4.sub (f32x4.mul (local.get $w1r) (local.get $br))
                                   (f32x4.mul (local.get $w1i) (local.get $bi))))
        (local.set $wbi (f32x4.add (f32x4.mul (local.get $w1r) (local.get $bi))
                                   (f32x4.mul (local.get $w1i) (local.get $br))))
        (local.set $wdr (f32x4.sub (f32x4.mul (local.get $w3r) (local.get $dr))
                                   (f32x4.mul (local.get $w3i) (local.get $di))))
        (local.set $wdi (f32x4.add (f32x4.mul (local.get $w3r) (local.get $di))
                                   (f32x4.mul (local.get $w3i) (local.get $dr))))

        (local.set $t0r (f32x4.add (local.get $ar) (local.get $wcr)))
        (local.set $t0i (f32x4.add (local.get $ai) (local.get $wci)))
        (local.set $t1r (f32x4.sub (local.get $ar) (local.get $wcr)))
        (local.set $t1i (f32x4.sub (local.get $ai) (local.get $wci)))
        (local.set $t2r (f32x4.add (local.get $wbr) (local.get $wdr)))
        (local.set $t2i (f32x4.add (local.get $wbi) (local.get $wdi)))
        (local.set $t3r (f32x4.sub (local.get $wbr) (local.get $wdr)))
        (local.set $t3i (f32x4.sub (local.get $wbi) (local.get $wdi)))

        ;; outputs q = j..j+3 contiguous in each quarter block
        (local.set $q (i32.shl (local.get $j) (i32.const 2)))

        (v128.store (i32.add (local.get $dst_re) (local.get $q))
          (f32x4.add (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $dst_im) (local.get $q))
          (f32x4.add (local.get $t0i) (local.get $t2i)))

        (local.set $q (i32.add (local.get $q) (local.get $n4b)))
        (v128.store (i32.add (local.get $dst_re) (local.get $q))
          (f32x4.add (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $dst_im) (local.get $q))
          (f32x4.sub (local.get $t1i) (local.get $t3r)))

        (local.set $q (i32.add (local.get $q) (local.get $n4b)))
        (v128.store (i32.add (local.get $dst_re) (local.get $q))
          (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $dst_im) (local.get $q))
          (f32x4.sub (local.get $t0i) (local.get $t2i)))

        (local.set $q (i32.add (local.get $q) (local.get $n4b)))
        (v128.store (i32.add (local.get $dst_re) (local.get $q))
          (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $dst_im) (local.get $q))
          (f32x4.add (local.get $t1i) (local.get $t3r)))

        (local.set $j (i32.add (local.get $j) (i32.const 4)))
        (br $loop)
      )
    )
  )

  ;; Full transform for n = 4^p. Result lands in SRC planes when the stage
  ;; count is even, DST planes when odd (harness reads `fft_r4`'s return: 0 =
  ;; SRC planes, 1 = DST planes).
  (func (export "fft_r4") (param $n i32) (result i32)
    (local $s i32)
    (local $l i32)
    (local $tw i32)
    (local $sr i32) (local $si i32)
    (local $dr i32) (local $di i32)
    (local $tmp i32)
    (local $parity i32)

    (local.set $s (i32.shr_u (local.get $n) (i32.const 2)))
    (local.set $l (i32.const 1))
    (local.set $tw (global.get $TW))
    (local.set $sr (global.get $SRC_RE))
    (local.set $si (global.get $SRC_IM))
    (local.set $dr (global.get $DST_RE))
    (local.set $di (global.get $DST_IM))
    (local.set $parity (i32.const 0))

    (block $done
      (loop $stages
        (br_if $done (i32.lt_u (local.get $s) (i32.const 1)))

        (if (i32.ge_u (local.get $s) (i32.const 4))
          (then
            (call $stage_generic (local.get $sr) (local.get $si)
                                 (local.get $dr) (local.get $di)
                                 (local.get $s) (local.get $l)
                                 (local.get $tw) (local.get $n)))
          (else
            (call $stage_s1 (local.get $sr) (local.get $si)
                            (local.get $dr) (local.get $di)
                            (local.get $l) (local.get $tw) (local.get $n))))

        ;; swap src/dst planes
        (local.set $tmp (local.get $sr)) (local.set $sr (local.get $dr)) (local.set $dr (local.get $tmp))
        (local.set $tmp (local.get $si)) (local.set $si (local.get $di)) (local.set $di (local.get $tmp))
        (local.set $parity (i32.xor (local.get $parity) (i32.const 1)))

        ;; advance: tw += 6*l floats = 24*l bytes; l *= 4; s /= 4
        (local.set $tw (i32.add (local.get $tw) (i32.mul (local.get $l) (i32.const 24))))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
        (local.set $s (i32.shr_u (local.get $s) (i32.const 2)))
        (br $stages)
      )
    )

    (local.get $parity)
  )
)
