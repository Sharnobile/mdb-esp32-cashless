/*
 * VMflow.xyz
 *
 * oled_display.h — SSD1306 128x64 I2C OLED text driver
 *
 * Minimal page-addressed text driver: the panel's 8 hardware pages (8px
 * each) map 1:1 to 8 text rows, so no font-height math is needed. On this
 * module the top 2 rows are the yellow strip and the bottom 6 are blue —
 * purely a coating on the glass, not something the controller knows about,
 * so callers just address rows 0-7 and the color follows from physical
 * position on the panel.
 */

#ifndef OLED_DISPLAY_H
#define OLED_DISPLAY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OLED_DISPLAY_ROWS 8
#define OLED_DISPLAY_COLS 21 /* 128px / 6px per glyph (5px font + 1px spacing) */

/*
 * Bring up the I2C bus and SSD1306 controller on PIN_I2C_SDA/PIN_I2C_SCL
 * (see mdb-slave-esp32s3.c). Call once from app_main().
 *
 * If no display answers on the bus (header unpopulated), this logs a
 * warning and leaves the driver disabled; oled_display_set_line() then
 * becomes a silent no-op so callers don't need to guard every call.
 */
void oled_display_init(void);

/*
 * Set text row `row` (0 = top yellow row ... 7 = bottom blue row) and push
 * it to the panel immediately. Text longer than OLED_DISPLAY_COLS is
 * truncated; shorter text is space-padded so stale characters from a
 * previous, longer string never linger on screen. NULL clears the row.
 */
void oled_display_set_line(uint8_t row, const char *text);

#ifdef __cplusplus
}
#endif

#endif /* OLED_DISPLAY_H */
