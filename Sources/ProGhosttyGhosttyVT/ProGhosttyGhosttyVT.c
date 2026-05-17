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

void proghostty_vt_scroll_viewport(ProGhosttyVT *vt, intptr_t delta_rows) {
  if (vt == NULL || vt->terminal == NULL || delta_rows == 0) {
    return;
  }

  GhosttyTerminalScrollViewport scroll = {
    .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
    .value = {.delta = delta_rows},
  };
  ghostty_terminal_scroll_viewport(vt->terminal, scroll);
}

int proghostty_vt_scrollbar(ProGhosttyVT *vt, ProGhosttyVTScrollbar *out) {
  if (vt == NULL || vt->terminal == NULL || out == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  GhosttyTerminalScrollbar scrollbar = {0};
  GhosttyResult result = ghostty_terminal_get(
    vt->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  out->total = scrollbar.total;
  out->offset = scrollbar.offset;
  out->length = scrollbar.len;
  return GHOSTTY_SUCCESS;
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
  cell.fg_default = true;
  cell.bg_default = true;
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
  bool fg_default = true;
  bool bg_default = true;
  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);

  GhosttyResult result = ghostty_render_state_row_cells_get(
    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
  if (result != GHOSTTY_SUCCESS) {
    fg = colors->foreground;
    fg_default = true;
  } else {
    fg_default = false;
  }

  result = ghostty_render_state_row_cells_get(
    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
  if (result != GHOSTTY_SUCCESS) {
    bg = colors->background;
    bg_default = true;
  } else {
    bg_default = false;
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

  cell->fg_r = fg.r;
  cell->fg_g = fg.g;
  cell->fg_b = fg.b;
  cell->bg_r = bg.r;
  cell->bg_g = bg.g;
  cell->bg_b = bg.b;
  cell->fg_default = fg_default;
  cell->bg_default = bg_default;
}

static GhosttyColorRgb style_color_rgb(GhosttyStyleColor color, GhosttyRenderStateColors *colors, GhosttyColorRgb fallback, bool *is_default) {
  if (is_default != NULL) {
    *is_default = false;
  }

  switch (color.tag) {
    case GHOSTTY_STYLE_COLOR_RGB:
      return color.value.rgb;
    case GHOSTTY_STYLE_COLOR_PALETTE:
      return colors->palette[color.value.palette];
    case GHOSTTY_STYLE_COLOR_NONE:
    default:
      if (is_default != NULL) {
        *is_default = true;
      }
      return fallback;
  }
}

static ProGhosttyVTCell cell_from_grid_ref(GhosttyGridRef *ref, GhosttyRenderStateColors *colors) {
  ProGhosttyVTCell out = blank_cell(colors);
  GhosttyCell raw = 0;
  if (ghostty_grid_ref_cell(ref, &raw) != GHOSTTY_SUCCESS) {
    return out;
  }

  uint32_t codepoints[8] = {0};
  size_t grapheme_len = 0;
  if (ghostty_grid_ref_graphemes(ref, codepoints, 8, &grapheme_len) == GHOSTTY_SUCCESS && grapheme_len > 0) {
    out.codepoint = codepoints[0] == 0 ? ' ' : codepoints[0];
  } else {
    uint32_t codepoint = 0;
    if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint) == GHOSTTY_SUCCESS && codepoint != 0) {
      out.codepoint = codepoint;
    }
  }

  GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
  if (ghostty_grid_ref_style(ref, &style) == GHOSTTY_SUCCESS) {
    GhosttyColorRgb fg = style_color_rgb(style.fg_color, colors, colors->foreground, &out.fg_default);
    GhosttyColorRgb bg = style_color_rgb(style.bg_color, colors, colors->background, &out.bg_default);
    out.fg_r = fg.r;
    out.fg_g = fg.g;
    out.fg_b = fg.b;
    out.bg_r = bg.r;
    out.bg_g = bg.g;
    out.bg_b = bg.b;
    out.bold = style.bold;
    out.italic = style.italic;
    out.faint = style.faint;
    out.underline = style.underline != 0;
    out.inverse = style.inverse;
  }

  GhosttyCellContentTag content_tag = GHOSTTY_CELL_CONTENT_CODEPOINT;
  if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &content_tag) == GHOSTTY_SUCCESS) {
    if (content_tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
      GhosttyColorRgb bg = colors->background;
      if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &bg) == GHOSTTY_SUCCESS) {
        out.bg_r = bg.r;
        out.bg_g = bg.g;
        out.bg_b = bg.b;
        out.bg_default = false;
      }
    } else if (content_tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
      GhosttyColorPaletteIndex palette = 0;
      if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &palette) == GHOSTTY_SUCCESS) {
        GhosttyColorRgb bg = colors->palette[palette];
        out.bg_r = bg.r;
        out.bg_g = bg.g;
        out.bg_b = bg.b;
        out.bg_default = false;
      }
    }
  }

  return out;
}

static int copy_screen_rows(
  ProGhosttyVT *vt,
  GhosttyRenderStateColors *colors,
  uint64_t start_row,
  size_t row_count,
  uint16_t cols,
  ProGhosttyVTCell **out_cells
) {
  *out_cells = NULL;
  if (row_count == 0) {
    return GHOSTTY_SUCCESS;
  }

  size_t cell_count = row_count * (size_t)cols;
  ProGhosttyVTCell *cells = calloc(cell_count, sizeof(ProGhosttyVTCell));
  if (cells == NULL) {
    return GHOSTTY_OUT_OF_MEMORY;
  }

  for (size_t i = 0; i < cell_count; i++) {
    cells[i] = blank_cell(colors);
  }

  for (size_t row = 0; row < row_count; row++) {
    uint64_t screen_y = start_row + row;
    if (screen_y > UINT32_MAX) {
      continue;
    }

    for (uint16_t x = 0; x < cols; x++) {
      GhosttyPoint point = {
        .tag = GHOSTTY_POINT_TAG_SCREEN,
        .value = {.coordinate = {.x = x, .y = (uint32_t)screen_y}},
      };
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      if (ghostty_terminal_grid_ref(vt->terminal, point, &ref) != GHOSTTY_SUCCESS) {
        continue;
      }
      cells[row * (size_t)cols + x] = cell_from_grid_ref(&ref, colors);
    }
  }

  *out_cells = cells;
  return GHOSTTY_SUCCESS;
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
  bool cursor_blinking = false;
  GhosttyTerminalScreen active_screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  GhosttyRenderStateCursorVisualStyle cursor_visual_style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  uint16_t cursor_x = 0;
  uint16_t cursor_y = 0;
  ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &cursor_blinking);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_visual_style);
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
  out->cursor_visual_style = (uint8_t)cursor_visual_style;
  out->cursor_blinking = cursor_blinking;
  out->alternate_screen = active_screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
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

int proghostty_vt_scroll_snapshot(
  ProGhosttyVT *vt,
  uint16_t overscan_top,
  uint16_t overscan_bottom,
  ProGhosttyVTScrollSnapshot *out
) {
  if (vt == NULL || vt->terminal == NULL || vt->render_state == NULL || out == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  memset(out, 0, sizeof(ProGhosttyVTScrollSnapshot));
  out->requested_overscan_top = overscan_top;
  out->requested_overscan_bottom = overscan_bottom;

  GhosttyResult result = proghostty_vt_snapshot(vt, &out->viewport);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  ProGhosttyVTScrollbar scrollbar = {0};
  result = proghostty_vt_scrollbar(vt, &scrollbar);
  if (result != GHOSTTY_SUCCESS) {
    proghostty_vt_scroll_snapshot_free(out);
    return result;
  }
  out->viewport_start_row = scrollbar.offset;

  if (out->viewport.alternate_screen || out->viewport.cols == 0) {
    return GHOSTTY_SUCCESS;
  }

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  result = ghostty_render_state_colors_get(vt->render_state, &colors);
  if (result != GHOSTTY_SUCCESS) {
    proghostty_vt_scroll_snapshot_free(out);
    return result;
  }

  uint16_t top_request = overscan_top > 2 ? 2 : overscan_top;
  uint16_t bottom_request = overscan_bottom > 2 ? 2 : overscan_bottom;
  uint64_t viewport_start = scrollbar.offset;
  uint64_t viewport_end = scrollbar.offset + scrollbar.length;
  uint64_t total = scrollbar.total;

  uint64_t top_start = viewport_start > top_request ? viewport_start - top_request : 0;
  size_t top_rows = (size_t)(viewport_start - top_start);
  uint64_t bottom_end = viewport_end + bottom_request;
  if (bottom_end > total) {
    bottom_end = total;
  }
  size_t bottom_rows = viewport_end < bottom_end ? (size_t)(bottom_end - viewport_end) : 0;

  result = copy_screen_rows(vt, &colors, top_start, top_rows, out->viewport.cols, &out->overscan_top_cells);
  if (result != GHOSTTY_SUCCESS) {
    proghostty_vt_scroll_snapshot_free(out);
    return result;
  }
  out->overscan_top_rows = top_rows;

  result = copy_screen_rows(vt, &colors, viewport_end, bottom_rows, out->viewport.cols, &out->overscan_bottom_cells);
  if (result != GHOSTTY_SUCCESS) {
    proghostty_vt_scroll_snapshot_free(out);
    return result;
  }
  out->overscan_bottom_rows = bottom_rows;

  return GHOSTTY_SUCCESS;
}

void proghostty_vt_scroll_snapshot_free(ProGhosttyVTScrollSnapshot *snapshot) {
  if (snapshot == NULL) {
    return;
  }
  proghostty_vt_snapshot_free(&snapshot->viewport);
  free(snapshot->overscan_top_cells);
  free(snapshot->overscan_bottom_cells);
  snapshot->overscan_top_cells = NULL;
  snapshot->overscan_bottom_cells = NULL;
  snapshot->overscan_top_rows = 0;
  snapshot->overscan_bottom_rows = 0;
}

static int proghostty_vt_format(ProGhosttyVT *vt, GhosttyFormatterFormat format, uint8_t **out, size_t *out_len) {
  if (vt == NULL || vt->terminal == NULL || out == NULL || out_len == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  opts.emit = format;
  opts.trim = true;
  opts.extra.palette = format == GHOSTTY_FORMATTER_FORMAT_HTML;

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
