  (func $sub (export "sub") (param $a i32) (param $b i32) (result i32)
    (i32.sub (local.get $a) (local.get $b))
  )
