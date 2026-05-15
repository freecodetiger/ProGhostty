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
  bool bold;
  bool italic;
  bool faint;
  bool underline;
  bool inverse;
} ProGhosttyVTCell;

typedef struct {
  uint16_t cols;
  uint16_t rows;
  bool cursor_visible;
  uint16_t cursor_x;
  uint16_t cursor_y;
  ProGhosttyVTCell *cells;
  size_t cell_count;
} ProGhosttyVTSnapshot;

int proghostty_vt_new(uint16_t cols, uint16_t rows, size_t max_scrollback, ProGhosttyVT **out);
void proghostty_vt_free(ProGhosttyVT *vt);
void proghostty_vt_write(ProGhosttyVT *vt, const uint8_t *data, size_t len);
int proghostty_vt_resize(ProGhosttyVT *vt, uint16_t cols, uint16_t rows);
int proghostty_vt_snapshot(ProGhosttyVT *vt, ProGhosttyVTSnapshot *out);
void proghostty_vt_snapshot_free(ProGhosttyVTSnapshot *snapshot);
int proghostty_vt_format_plain(ProGhosttyVT *vt, uint8_t **out, size_t *out_len);
int proghostty_vt_format_html(ProGhosttyVT *vt, uint8_t **out, size_t *out_len);
void proghostty_vt_free_bytes(uint8_t *ptr, size_t len);

#endif
