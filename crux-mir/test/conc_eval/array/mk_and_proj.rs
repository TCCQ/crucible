#![cfg_attr(not(with_main), no_std)]
fn f(x: u8) -> u8 {
    let xs = [x; 4];
    xs[0]
}

const ARG: u8 = 42;

#[cfg(with_main)]
pub fn main() {
    println!("{:?}", f(ARG));
}
#[cfg(not(with_main))] #[crux_test] fn crux_test() -> u8 { f(ARG) }
