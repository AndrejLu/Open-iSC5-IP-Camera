# GPIO / IR map (from live fanghacks + stock rcS)

## Confirmed
| Function | Control | Notes |
|----------|---------|-------|
| Sensor power | `gpio_ms1 -n 6 -m 1 -v 1` | stock `rcS` |
| IR-cut (day) | `gpio_ms1 -n 2 -m 1 -v 1` | `fang-ir-control.sh` |
| IR-cut (night) | `gpio_ms1 -n 2 -m 1 -v 0` | same |
| Day sensor | `gpio_aud read 2` | `1`=day, else night |
| IR LED path | `gpio_aud write …` | see script |
| ISP sat day | `echo 0x40 > /proc/isp/filter/saturation` | |
| ISP sat night | `echo 0x0 > /proc/isp/filter/saturation` | |

## Tools
- `gpio_led -n 0..4` — pwm2/pwm1/GPIO2/GPIO3/pwm3 (LED candidates; **not yet mapped to colors**; several return busy/fail when claimed)
- `gpio_ms1 -n 1..14` except 8,9,10 — pin 6 read high after sensor power-on
- Button: **TBD** — iSC3S references `/sys/class/gpio` but no fang script documents the reset/setup button pin yet; needs press-and-watch probe (physical)

## Source
`/media/mmcblk0p2/data/usr/bin/fang-ir-control.sh` (archived under `firmware/sd-archive/`).
