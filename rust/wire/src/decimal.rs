use std::fmt::{self, Write};

/// A wire number with the Swift baseline's 128-bit Decimal significand and exponent range.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Decimal {
    magnitude: u128,
    exponent: i8,
    negative: bool,
}

impl Decimal {
    pub(crate) fn parse(mut token: &[u8]) -> Option<Self> {
        let negative = take(&mut token, b'-');
        let whole = digits(&mut token);
        if whole.is_empty() || (whole.len() > 1 && whole[0] == b'0') {
            return None;
        }
        let fraction = if take(&mut token, b'.') {
            let fraction = digits(&mut token);
            if fraction.is_empty() {
                return None;
            }
            fraction
        } else {
            &[]
        };

        let mut magnitude = 0_u128;
        let mut scale = 0_i64;
        let mut full = false;
        for (digit, fractional) in whole
            .iter()
            .map(|digit| (*digit, false))
            .chain(fraction.iter().map(|digit| (*digit, true)))
        {
            // Beyond the significand's capacity, Swift discards low digits without rounding.
            let appended = if full {
                None
            } else {
                magnitude
                    .checked_mul(10)
                    .and_then(|prefix| prefix.checked_add(u128::from(digit - b'0')))
            };
            if let Some(next) = appended {
                magnitude = next;
                scale -= i64::from(fractional);
            } else {
                full = true;
                scale += i64::from(!fractional);
            }
        }

        if take(&mut token, b'e') || take(&mut token, b'E') {
            let negative_exponent = take(&mut token, b'-');
            if !negative_exponent {
                take(&mut token, b'+');
            }
            let exponent = digits(&mut token);
            if exponent.is_empty() {
                return None;
            }
            let power = exponent.iter().fold(0_i64, |sum, digit| {
                sum.saturating_mul(10)
                    .saturating_add(i64::from(digit - b'0'))
            });
            scale = if negative_exponent {
                scale.saturating_sub(power)
            } else {
                scale.saturating_add(power)
            };
        }
        if !token.is_empty() {
            return None;
        }
        let mut exponent = i8::try_from(scale).ok()?;
        if magnitude == 0 {
            return Some(Self::from(0));
        }
        while exponent < i8::MAX && magnitude.is_multiple_of(10) {
            magnitude /= 10;
            exponent += 1;
        }
        Some(Self {
            magnitude,
            exponent,
            negative,
        })
    }

    pub fn as_i64(self) -> Option<i64> {
        let power = u32::try_from(self.exponent).ok()?;
        let magnitude = self.magnitude.checked_mul(10_u128.checked_pow(power)?)?;
        if self.negative {
            let magnitude = i128::try_from(magnitude).ok()?;
            i64::try_from(-magnitude).ok()
        } else {
            i64::try_from(magnitude).ok()
        }
    }
}

impl From<i64> for Decimal {
    fn from(value: i64) -> Self {
        let mut magnitude = u128::from(value.unsigned_abs());
        let mut exponent = 0;
        while magnitude != 0 && magnitude.is_multiple_of(10) {
            magnitude /= 10;
            exponent += 1;
        }
        Self {
            magnitude,
            exponent,
            negative: value.is_negative(),
        }
    }
}

impl fmt::Display for Decimal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.negative {
            f.write_char('-')?;
        }
        let digits = self.magnitude.to_string();
        if self.exponent >= 0 {
            f.write_str(&digits)?;
            for _ in 0..self.exponent {
                f.write_char('0')?;
            }
        } else {
            let places = usize::from(self.exponent.unsigned_abs());
            if digits.len() > places {
                let (whole, fraction) = digits.split_at(digits.len() - places);
                write!(f, "{whole}.{fraction}")?;
            } else {
                f.write_str("0.")?;
                for _ in digits.len()..places {
                    f.write_char('0')?;
                }
                f.write_str(&digits)?;
            }
        }
        Ok(())
    }
}

fn take(bytes: &mut &[u8], expected: u8) -> bool {
    if let Some(rest) = bytes.strip_prefix(&[expected]) {
        *bytes = rest;
        true
    } else {
        false
    }
}

fn digits<'a>(bytes: &mut &'a [u8]) -> &'a [u8] {
    let end = bytes
        .iter()
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    let (digits, rest) = bytes.split_at(end);
    *bytes = rest;
    digits
}
