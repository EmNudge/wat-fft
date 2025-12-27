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
    (local $term f64)
    (local $result f64)

    (local.set $normalized_x (call $normalize_angle (local.get $x)))
    (local.set $x_squared (f64.mul (local.get $normalized_x) (local.get $normalized_x)))

    ;; Taylor series for cos(x) = 1 - x^2/2! + x^4/4! - x^6/6! + x^8/8! - x^10/10! + x^12/12!
    (local.set $result (f64.const 1))

    ;; - x^2/2!
    (local.set $term (f64.div (local.get $x_squared) (f64.const 2)))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^4/4!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 12))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    ;; - x^6/6!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 30))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^8/8!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 56))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    ;; - x^10/10!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 90))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^12/12!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 132))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.get $result)
  )

  (func $sin (export "sin") (param $x f64) (result f64)
    (local $normalized_x f64)
    (local $x_squared f64)
    (local $term f64)
    (local $result f64)

    (local.set $normalized_x (call $normalize_angle (local.get $x)))
    (local.set $x_squared (f64.mul (local.get $normalized_x) (local.get $normalized_x)))

    ;; Taylor series for sin(x) = x - x^3/3! + x^5/5! - x^7/7! + x^9/9! - x^11/11! + x^13/13!
    (local.set $result (local.get $normalized_x))
    (local.set $term (local.get $normalized_x))

    ;; - x^3/3!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 6))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^5/5!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 20))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    ;; - x^7/7!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 42))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^9/9!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 72))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    ;; - x^11/11!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 110))))
    (local.set $result (f64.sub (local.get $result) (local.get $term)))

    ;; + x^13/13!
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x_squared) (f64.const 156))))
    (local.set $result (f64.add (local.get $result) (local.get $term)))

    (local.get $result)
  )
)