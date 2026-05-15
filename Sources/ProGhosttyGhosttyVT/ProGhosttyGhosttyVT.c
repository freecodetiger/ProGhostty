#include "ProGhosttyGhosttyVT.h"

#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

struct ProGhosttyVT {
  GhosttyTerminal terminal;
  GhosttyRenderState render_state;
};

int proghostty_vt_new(uint16_t cols, uint16_t rows, size_t max_scrollback, ProGhosttyVT **out) {
  if (out == NULL || cols == 0 || rows == 0) {
    return GHOSTTY_INVALID_VALUE;
  }

  ProGhosttyVT *vt = calloc(1, sizeof(ProGhosttyVT));
  if (vt == NULL) {
    return GHOSTTY_OUT_OF_MEMORY;
  }

  GhosttyTerminalOptions opts = {
    .cols = cols,
    .rows = rows,
    .max_scrollback = max_scrollback,
  };

  GhosttyResult result = ghostty_terminal_new(NULL, &vt->terminal, opts);
  if (result != GHOSTTY_SUCCESS) {
    free(vt);
    return result;
  }

  result = ghostty_render_state_new(NULL, &vt->render_state);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_terminal_free(vt->terminal);
    free(vt);
    return result;
  }

  *out = vt;
  return GHOSTTY_SUCCESS;
}

void proghostty_vt_free(ProGhosttyVT *vt) {
  if (vt == NULL) {
    return;
  }
  ghostty_render_state_free(vt->render_state);
  ghostty_terminal_free(vt->terminal);
  free(vt);
}

void proghostty_vt_write(ProGhosttyVT *vt, const uint8_t *data, size_t len) {
  if (vt == NULL || vt->terminal == NULL || data == NULL || len == 0) {
    return;
  }
  ghostty_terminal_vt_write(vt->terminal, data, len);
}

int proghostty_vt_resize(ProGhosttyVT *vt, uint16_t cols, uint16_t rows) {
  if (vt == NULL || vt->terminal == NULL || cols == 0 || rows == 0) {
    return GHOSTTY_INVALID_VALUE;
  }
  return ghostty_terminal_resize(vt->terminal, cols, rows, 8, 16);
}

static ProGhosttyVTCell blank_cell(GhosttyRenderStateColors *colors) {
  ProGhosttyVTCell cell;
  cell.codepoint = ' ';
  cell.fg_r = colors->foreground.r;
  cell.fg_g = colors->foreground.g;
  cell.fg_b = colors->foreground.b;
  cell.bg_r = colors->background.r;
  cell.bg_g = colors->background.g;
  cell.bg_b = colors->background.b;
  cell.bold = false;
  cell.italic = false;
  cell.faint = false;
  cell.underline = false;
  cell.inverse = false;
  return cell;
}

static void apply_style(ProGhosttyVTCell *cell, GhosttyRenderStateRowCells cells, GhosttyRenderStateColors *colors) {
  GhosttyColorRgb fg = colors->foreground;
  GhosttyColorRgb bg = colors->background;
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);

  GhosttyResult result = ghostty_render_state_row_cells_get(
    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
  if (result != GHOSTTY_SUCCESS) {
    fg = colors->foreground;
  }

  result = ghostty_render_state_row_cells_get(
    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
  if (result != GHOSTTY_SUCCESS) {
    bg = colors->background;
  }

  result = ghostty_render_state_row_cells_get(
    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
  if (result == GHOSTTY_SUCCESS) {
    cell->bold = style.bold;
    cell->italic = style.italic;
    cell->faint = style.faint;
    cell->underline = style.underline != 0;
    cell->inverse = style.inverse;
  }

  if (cell->inverse) {
    GhosttyColorRgb tmp = fg;
    fg = bg;
    bg = tmp;
  }

  cell->fg_r = fg.r;
  cell->fg_g = fg.g;
  cell->fg_b = fg.b;
  cell->bg_r = bg.r;
  cell->bg_g = bg.g;
  cell->bg_b = bg.b;
}

int proghostty_vt_snapshot(ProGhosttyVT *vt, ProGhosttyVTSnapshot *out) {
  if (vt == NULL || vt->terminal == NULL || vt->render_state == NULL || out == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  memset(out, 0, sizeof(ProGhosttyVTSnapshot));
  GhosttyResult result = ghostty_render_state_update(vt->render_state, vt->terminal);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  uint16_t cols = 0;
  uint16_t rows = 0;
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  if (cols == 0 || rows == 0) {
    return GHOSTTY_INVALID_VALUE;
  }

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  result = ghostty_render_state_colors_get(vt->render_state, &colors);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  size_t cell_count = (size_t)cols * (size_t)rows;
  ProGhosttyVTCell *cells_out = calloc(cell_count, sizeof(ProGhosttyVTCell));
  if (cells_out == NULL) {
    return GHOSTTY_OUT_OF_MEMORY;
  }

  for (size_t i = 0; i < cell_count; i++) {
    cells_out[i] = blank_cell(&colors);
  }

  GhosttyRenderStateRowIterator row_iter = NULL;
  result = ghostty_render_state_row_iterator_new(NULL, &row_iter);
  if (result != GHOSTTY_SUCCESS) {
    free(cells_out);
    return result;
  }

  result = ghostty_render_state_get(
    vt->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_render_state_row_iterator_free(row_iter);
    free(cells_out);
    return result;
  }

  GhosttyRenderStateRowCells row_cells = NULL;
  result = ghostty_render_state_row_cells_new(NULL, &row_cells);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_render_state_row_iterator_free(row_iter);
    free(cells_out);
    return result;
  }

  uint16_t y = 0;
  while (y < rows && ghostty_render_state_row_iterator_next(row_iter)) {
    result = ghostty_render_state_row_get(
      row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &row_cells);
    if (result != GHOSTTY_SUCCESS) {
      break;
    }

    for (uint16_t x = 0; x < cols; x++) {
      result = ghostty_render_state_row_cells_select(row_cells, x);
      if (result != GHOSTTY_SUCCESS) {
        continue;
      }

      ProGhosttyVTCell *cell = &cells_out[(size_t)y * cols + x];
      uint32_t grapheme_len = 0;
      ghostty_render_state_row_cells_get(
        row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);
      if (grapheme_len > 0) {
        uint32_t codepoints[8] = {0};
        ghostty_render_state_row_cells_get(
          row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
        cell->codepoint = codepoints[0] == 0 ? ' ' : codepoints[0];
      }
      apply_style(cell, row_cells, &colors);
    }
    y++;
  }

  bool cursor_visible = false;
  bool cursor_has_value = false;
  uint16_t cursor_x = 0;
  uint16_t cursor_y = 0;
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursor_has_value);
  if (cursor_visible && cursor_has_value) {
    ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x);
    ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y);
  }

  ghostty_render_state_row_cells_free(row_cells);
  ghostty_render_state_row_iterator_free(row_iter);

  out->cols = cols;
  out->rows = rows;
  out->cursor_visible = cursor_visible && cursor_has_value;
  out->cursor_x = cursor_x;
  out->cursor_y = cursor_y;
  out->cells = cells_out;
  out->cell_count = cell_count;
  return GHOSTTY_SUCCESS;
}

void proghostty_vt_snapshot_free(ProGhosttyVTSnapshot *snapshot) {
  if (snapshot == NULL) {
    return;
  }
  free(snapshot->cells);
  snapshot->cells = NULL;
  snapshot->cell_count = 0;
}

static int proghostty_vt_format(ProGhosttyVT *vt, GhosttyFormatterFormat format, uint8_t **out, size_t *out_len) {
  if (vt == NULL || vt->terminal == NULL || out == NULL || out_len == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  opts.emit = format;
  opts.trim = true;

  GhosttyFormatter formatter = NULL;
  GhosttyResult result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal, opts);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  result = ghostty_formatter_format_alloc(formatter, NULL, out, out_len);
  ghostty_formatter_free(formatter);
  return result;
}

int proghostty_vt_format_plain(ProGhosttyVT *vt, uint8_t **out, size_t *out_len) {
  return proghostty_vt_format(vt, GHOSTTY_FORMATTER_FORMAT_PLAIN, out, out_len);
}

int proghostty_vt_format_html(ProGhosttyVT *vt, uint8_t **out, size_t *out_len) {
  return proghostty_vt_format(vt, GHOSTTY_FORMATTER_FORMAT_HTML, out, out_len);
}

void proghostty_vt_free_bytes(uint8_t *ptr, size_t len) {
  if (ptr == NULL) {
    return;
  }
  ghostty_free(NULL, ptr, len);
}
