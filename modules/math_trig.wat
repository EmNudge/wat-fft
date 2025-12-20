(module
  (global $PI (export "PI") f64 (f64.const 3.141592653589793))
  (global $TWO_PI (export "TWO_PI") f64 (f64.const 6.283185307179586))

  (func $normalize_angle (param $x f64) (result f64)
    (local $remainder f64)
    (local.set $remainder
      (f64.sub
        (local.get $x)
        (f64.mul
          (f64.floor (f64.div (local.get $x) (global.get $TWO_PI)))
          (global.get $TWO_PI)
        )
      )
    )
    (if (result f64) (f64.lt (local.get $remainder) (f64.const 0))
      (then
        (f64.add (local.get $remainder) (global.get $TWO_PI))
      )
      (else
        (local.get $remainder)
      )
    )
  )

  (func $cos (export "cos") (param $x f64) (result f64)
    (local $normalized_x f64)
    (local $x_squared f64)
    (local $x_fourth f64)

    (local.set $normalized_x (call $normalize_angle (local.get $x)))

    ;; Taylor series for cos(x) = 1 - x^2/2! + x^4/4!
    (local.set $x_squared (f64.mul (local.get $normalized_x) (local.get $normalized_x)))
    (local.set $x_fourth (f64.mul (local.get $x_squared) (local.get $x_squared)))

    (f64.sub
      (f64.add
        (f64.const 1)
        (f64.div (local.get $x_fourth) (f64.const 24)) ;; 4!
      )
      (f64.div (local.get $x_squared) (f64.const 2))  ;; 2!
    )
  )

  (func $sin (export "sin") (param $x f64) (result f64)
    (local $normalized_x f64)
    (local $x_squared f64)
    (local $x_cubed f64)
    (local $x_fifth f64)

    (local.set $normalized_x (call $normalize_angle (local.get $x)))

    ;; Taylor series for sin(x) = x - x^3/3! + x^5/5!
    (local.set $x_squared (f64.mul (local.get $normalized_x) (local.get $normalized_x)))
    (local.set $x_cubed (f64.mul (local.get $x_squared) (local.get $normalized_x)))
    (local.set $x_fifth (f64.mul (local.get $x_cubed) (local.get $x_squared)))

    (f64.sub
      (f64.add
        (local.get $normalized_x)
        (f64.div (local.get $x_fifth) (f64.const 120)) ;; 5!
      )
      (f64.div (local.get $x_cubed) (f64.const 6))  ;; 3!
    )
  )
)