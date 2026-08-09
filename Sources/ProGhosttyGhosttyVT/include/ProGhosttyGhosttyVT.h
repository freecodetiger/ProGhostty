#ifndef PROGHOSTTY_GHOSTTY_VT_H
#define PROGHOSTTY_GHOSTTY_VT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct ProGhosttyVT ProGhosttyVT;

typedef struct {
  uint32_t codepoint;
  uint8_t fg_r;
  uint8_t fg_g;
  uint8_t fg_b;
  uint8_t bg_r;
  uint8_t bg_g;
  uint8_t bg_b;
  bool fg_default;
  bool bg_default;
  bool bold;
  bool italic;
  bool faint;
  bool underline;
  bool inverse;
  uint8_t wide;
  uint8_t semantic_content; // 0=output, 1=input, 2=prompt
  uint8_t *hyperlink_uri;
  size_t hyperlink_uri_len;
} ProGhosttyVTCell;

typedef struct {
  uint16_t cols;
  uint16_t rows;
  bool cursor_visible;
  uint16_t cursor_x;
  uint16_t cursor_y;
  uint8_t cursor_visual_style;
  bool cursor_blinking;
  bool alternate_screen;
  uint8_t cursor_semantic_content; // 0=output, 1=input, 2=prompt (active screen cursor)
  ProGhosttyVTCell *cells;
  size_t cell_count;
} ProGhosttyVTSnapshot;

typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t length;
} ProGhosttyVTScrollbar;

typedef struct {
  ProGhosttyVTSnapshot viewport;
  ProGhosttyVTCell *overscan_top_cells;
  size_t overscan_top_rows;
  ProGhosttyVTCell *overscan_bottom_cells;
  size_t overscan_bottom_rows;
  uint16_t requested_overscan_top;
  uint16_t requested_overscan_bottom;
  uint64_t viewport_start_row;
} ProGhosttyVTScrollSnapshot;

// A bare window of rows fetched directly by absolute scrollback row number,
// with no viewport/overscan geometry. This is the pattern-2 primitive: the
// renderer asks for exactly the rows it needs to draw at a given scroll
// position. `start_row` is clamped into [0, total) and `row_count` truncated so
// `start_row + row_count <= total`; `rows` reflects what was actually copied.
typedef struct {
  ProGhosttyVTCell *cells;
  size_t rows;
  uint16_t cols;
  uint64_t start_row;
  uint64_t total;
} ProGhosttyVTRows;

typedef enum {
  PROGHOSTTY_VT_SCROLL_LOCAL = 0,
  PROGHOSTTY_VT_SCROLL_MOUSE_REPORTING = 1,
  PROGHOSTTY_VT_SCROLL_ALTERNATE_CURSOR_KEYS = 2,
  PROGHOSTTY_VT_SCROLL_CONSUMED = 3,
} ProGhosttyVTScrollOwnershipKind;

typedef struct {
  ProGhosttyVTScrollOwnershipKind kind;
  bool application_cursor_keys;
} ProGhosttyVTScrollOwnership;

typedef struct {
  bool wheel_up;
  bool shift;
  bool control;
  bool alt;
  float x;
  float y;
} ProGhosttyVTMouseEvent;

typedef struct {
  uint32_t screen_width;
  uint32_t screen_height;
  uint32_t cell_width;
  uint32_t cell_height;
  uint32_t padding_top;
  uint32_t padding_bottom;
  uint32_t padding_right;
  uint32_t padding_left;
} ProGhosttyVTMouseGeometry;

int proghostty_vt_new(uint16_t cols, uint16_t rows, size_t max_scrollback, ProGhosttyVT **out);
void proghostty_vt_free(ProGhosttyVT *vt);
void proghostty_vt_write(ProGhosttyVT *vt, const uint8_t *data, size_t len);
int proghostty_vt_resize(ProGhosttyVT *vt, uint16_t cols, uint16_t rows);
void proghostty_vt_scroll_viewport(ProGhosttyVT *vt, intptr_t delta_rows);
int proghostty_vt_scrollbar(ProGhosttyVT *vt, ProGhosttyVTScrollbar *out);
int proghostty_vt_snapshot(ProGhosttyVT *vt, ProGhosttyVTSnapshot *out);
void proghostty_vt_snapshot_free(ProGhosttyVTSnapshot *snapshot);
int proghostty_vt_scroll_snapshot(
  ProGhosttyVT *vt,
  uint16_t overscan_top,
  uint16_t overscan_bottom,
  ProGhosttyVTScrollSnapshot *out);
void proghostty_vt_scroll_snapshot_free(ProGhosttyVTScrollSnapshot *snapshot);
int proghostty_vt_rows_at(
  ProGhosttyVT *vt,
  uint64_t start_row,
  size_t row_count,
  ProGhosttyVTRows *out);
void proghostty_vt_rows_free(ProGhosttyVTRows *rows);
int proghostty_vt_format_plain(ProGhosttyVT *vt, uint8_t **out, size_t *out_len);
int proghostty_vt_format_html(ProGhosttyVT *vt, uint8_t **out, size_t *out_len);
int proghostty_vt_encode_paste(ProGhosttyVT *vt, const uint8_t *data, size_t len, uint8_t **out, size_t *out_len);
bool proghostty_vt_mouse_reporting_active(ProGhosttyVT *vt);
int proghostty_vt_scroll_ownership(ProGhosttyVT *vt, ProGhosttyVTScrollOwnership *out);
int proghostty_vt_encode_mouse(
  ProGhosttyVT *vt,
  const ProGhosttyVTMouseEvent *event,
  const ProGhosttyVTMouseGeometry *geometry,
  uint8_t **out,
  size_t *out_len);
int proghostty_vt_encode_alternate_scroll(
  ProGhosttyVT *vt,
  bool wheel_up,
  size_t count,
  uint8_t **out,
  size_t *out_len);
void proghostty_vt_free_bytes(uint8_t *ptr, size_t len);

#endif
