(module
  (global $PI (export "PI") f64 (f64.const 3.141592653589793))
  (global $TWO_PI (export "TWO_PI") f64 (f64.const 6.283185307179586))
  (global $HALF_PI f64 (f64.const 1.5707963267948966))

  ;; Reduce angle to [-π, π] range for better Taylor series convergence
  (func $normalize_angle (export "normalize_angle") (param $x f64) (result f64)
    (local $reduced f64)
    ;; First reduce to [0, 2π]
    (local.set $reduced
      (f64.sub
        (local.get $x)
        (f64.mul
          (f64.floor (f64.div (local.get $x) (global.get $TWO_PI)))
          (global.get $TWO_PI)
        )
      )
    )
    ;; Handle negative remainders
    (if (f64.lt (local.get $reduced) (f64.const 0))
      (then
        (local.set $reduced (f64.add (local.get $reduced) (global.get $TWO_PI)))
      )
    )
    ;; Shift to [-π, π] for better accuracy
    (if (result f64) (f64.gt (local.get $reduced) (global.get $PI))
      (then
        (f64.sub (local.get $reduced) (global.get $TWO_PI))
      )
      (else
        (local.get $reduced)
      )
    )
  )

  ;; Internal Taylor series for cos, expects x in [-π/2, π/2]
  (func $cos_taylor (param $x f64) (result f64)
    (local $x_squared f64)
    (local $term f64)
    (local $result f64)

    (local.set $x_squared (f64.mul (local.get $x) (local.get $x)))

    ;; Taylor series for cos(x) = 1 - x^2/2! + x^4/4! - x^6/6! + ...
    (local.set $result (f64.const 1))

    (local.set $term (f64.div (local.get $x_squared) (f64.const 2)))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 12))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 30))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 56))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 90))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 132))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.get $result)
  )

  ;; Internal Taylor series for sin, expects x in [-π/2, π/2]
  (func $sin_taylor (param $x f64) (result f64)
    (local $x_squared f64)
    (local $term f64)
    (local $result f64)

    (local.set $x_squared (f64.mul (local.get $x) (local.get $x)))

    ;; Taylor series for sin(x) = x - x^3/3! + x^5/5! - x^7/7! + ...
    (local.set $result (local.get $x))
    (local.set $term (local.get $x))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 6))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 20))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 42))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 72))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 110))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 156))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.get $result)
  )

  ;; cos with quadrant reduction: reduces to [-π/2, π/2] for best Taylor accuracy
  ;; Uses: cos(x) = -cos(π - x) for x in [π/2, π]
  ;;       cos(x) = -cos(x + π) for x in [-π, -π/2]
  (func $cos (export "cos") (param $x f64) (result f64)
    (local $reduced f64)

    ;; Reduce to [-π, π]
    (local.set $reduced (call $normalize_angle (local.get $x)))

    ;; If reduced > π/2, use cos(x) = -cos(π - x)
    (if (f64.gt (local.get $reduced) (global.get $HALF_PI))
      (then
        (return (f64.neg (call $cos_taylor (f64.sub (global.get $PI) (local.get $reduced)))))
      )
    )
    ;; If reduced < -π/2, use cos(x) = -cos(x + π)
    (if (f64.lt (local.get $reduced) (f64.neg (global.get $HALF_PI)))
      (then
        (return (f64.neg (call $cos_taylor (f64.add (local.get $reduced) (global.get $PI)))))
      )
    )
    ;; reduced is in [-π/2, π/2], use Taylor directly
    (call $cos_taylor (local.get $reduced))
  )

  ;; sin with quadrant reduction: reduces to [-π/2, π/2] for best Taylor accuracy
  ;; Uses: sin(x) = sin(π - x) for x in [π/2, π]
  ;;       sin(x) = sin(-π - x) for x in [-π, -π/2]
  (func $sin (export "sin") (param $x f64) (result f64)
    (local $reduced f64)

    ;; Reduce to [-π, π]
    (local.set $reduced (call $normalize_angle (local.get $x)))

    ;; If reduced > π/2, use sin(x) = sin(π - x)
    (if (f64.gt (local.get $reduced) (global.get $HALF_PI))
      (then
        (return (call $sin_taylor (f64.sub (global.get $PI) (local.get $reduced))))
      )
    )
    ;; If reduced < -π/2, use sin(x) = sin(-π - x) = -sin(π + x)
    (if (f64.lt (local.get $reduced) (f64.neg (global.get $HALF_PI)))
      (then
        (return (call $sin_taylor (f64.sub (f64.neg (global.get $PI)) (local.get $reduced))))
      )
    )
    ;; reduced is in [-π/2, π/2], use Taylor directly
    (call $sin_taylor (local.get $reduced))
  )
)