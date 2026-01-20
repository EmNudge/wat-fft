;; shared.wat - Canonical implementations of shared FFT utilities
;;
;; This file serves as the reference implementation for code that is duplicated
;; across multiple FFT modules. Each module keeps its own copy for these reasons:
;;   1. WAT files remain valid and self-contained for language server support
;;   2. Each module can be independently compiled and tested
;;   3. Minor variations may exist for algorithm-specific optimizations
;;
;; The build.js snippet system can parse this file using @snippet/@requires
;; markers, though currently modules maintain their own copies.
;;
;; When making changes to shared utilities:
;;   1. Update this file first (canonical source)
;;   2. Propagate changes to all modules that use the utility
;;   3. Run tests to verify consistency

;; ============================================
;; SIMD Complex Arithmetic
;; ============================================

;; @snippet SIGN_MASK
(global $SIGN_MASK v128 (v128.const i64x2 0x8000000000000000 0x0000000000000000))

;; @snippet simd_cmul
;; @requires SIGN_MASK
;; SIMD complex multiply: (a + bi)(c + di) = (ac-bd) + (ad+bc)i
(func $simd_cmul (param $a v128) (param $b v128) (result v128)
  (local $ar v128) (local $ai v128) (local $bd v128)
  (local.set $ar (f64x2.splat (f64x2.extract_lane 0 (local.get $a))))
  (local.set $ai (f64x2.splat (f64x2.extract_lane 1 (local.get $a))))
  (local.set $bd (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                (local.get $b) (local.get $b)))
  (f64x2.add
    (f64x2.mul (local.get $ar) (local.get $b))
    (f64x2.mul (v128.xor (local.get $ai) (global.get $SIGN_MASK)) (local.get $bd)))
)

;; @snippet mul_neg_j
;; Multiply by -j: (a+bi)*(-j) = b - ai => [a,b] -> [b, -a]
(func $mul_neg_j (param $v v128) (result v128)
  (f64x2.mul
    (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $v) (local.get $v))
    (v128.const f64x2 1.0 -1.0))
)

;; @snippet mul_pos_j
;; Multiply by +j: (a+bi)*j = -b + ai => [a,b] -> [-b, a]
(func $mul_pos_j (param $v v128) (result v128)
  (f64x2.mul
    (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $v) (local.get $v))
    (v128.const f64x2 -1.0 1.0))
)

;; ============================================
;; Bit/Digit Reversal
;; ============================================

;; @snippet bit_reverse
;; Reverse the bits of x within num_bits width
(func $bit_reverse (param $x i32) (param $num_bits i32) (result i32)
  (local $result i32)
  (local $i i32)
  (local.set $result (i32.const 0))
  (local.set $i (i32.const 0))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $num_bits)))
      (local.set $result (i32.or
        (i32.shl (local.get $result) (i32.const 1))
        (i32.and (local.get $x) (i32.const 1))))
      (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    )
  )
  (local.get $result)
)

;; @snippet bit_reverse_permute
;; @requires bit_reverse
;; In-place bit-reversal permutation of complex array
(func $bit_reverse_permute (param $n i32) (param $log2n i32)
  (local $i i32) (local $j i32)
  (local $addr_i i32) (local $addr_j i32)
  (local $tmp v128)
  (local.set $i (i32.const 0))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $j (call $bit_reverse (local.get $i) (local.get $log2n)))
      (if (i32.lt_u (local.get $i) (local.get $j))
        (then
          (local.set $addr_i (i32.shl (local.get $i) (i32.const 4)))
          (local.set $addr_j (i32.shl (local.get $j) (i32.const 4)))
          (local.set $tmp (v128.load (local.get $addr_i)))
          (v128.store (local.get $addr_i) (v128.load (local.get $addr_j)))
          (v128.store (local.get $addr_j) (local.get $tmp))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    )
  )
)

;; @snippet digit_reverse4
;; Reverse the base-4 digits of x within num_digits width
(func $digit_reverse4 (param $x i32) (param $num_digits i32) (result i32)
  (local $result i32)
  (local $i i32)
  (local.set $result (i32.const 0))
  (local.set $i (i32.const 0))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $num_digits)))
      (local.set $result (i32.or
        (i32.shl (local.get $result) (i32.const 2))
        (i32.and (local.get $x) (i32.const 3))))
      (local.set $x (i32.shr_u (local.get $x) (i32.const 2)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    )
  )
  (local.get $result)
)

;; @snippet digit_reverse_permute4
;; @requires digit_reverse4
;; In-place digit-reversal permutation for radix-4
(func $digit_reverse_permute4 (param $n i32) (param $num_digits i32)
  (local $i i32) (local $j i32)
  (local $addr_i i32) (local $addr_j i32)
  (local $tmp v128)
  (local.set $i (i32.const 0))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $j (call $digit_reverse4 (local.get $i) (local.get $num_digits)))
      (if (i32.lt_u (local.get $i) (local.get $j))
        (then
          (local.set $addr_i (i32.shl (local.get $i) (i32.const 4)))
          (local.set $addr_j (i32.shl (local.get $j) (i32.const 4)))
          (local.set $tmp (v128.load (local.get $addr_i)))
          (v128.store (local.get $addr_i) (v128.load (local.get $addr_j)))
          (v128.store (local.get $addr_j) (local.get $tmp))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    )
  )
)
