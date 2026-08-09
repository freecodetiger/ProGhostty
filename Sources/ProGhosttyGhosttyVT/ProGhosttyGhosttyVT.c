#include "ProGhosttyGhosttyVT.h"

#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

// Upper bound on overscan rows the scroll snapshot will materialize on each
// side of the viewport. Pixel-smooth scrolling renders a viewport + overscan
// band so the display link can translate the visible content by many rows per
// frame without a synchronous VT row commit. copy_screen_rows already supports
// an arbitrary row_count; this cap only bounds worst-case snapshot cost.
#define PROGHOSTTY_VT_MAX_OVERSCAN_ROWS 32

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

int proghostty_vt_encode_paste(ProGhosttyVT *vt, const uint8_t *data, size_t len, uint8_t **out, size_t *out_len) {
  if (out == NULL || out_len == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }
  *out = NULL;
  *out_len = 0;

  if (vt == NULL || vt->terminal == NULL || (data == NULL && len > 0)) {
    return GHOSTTY_INVALID_VALUE;
  }

  bool bracketed = false;
  GhosttyResult result = ghostty_terminal_mode_get(
    vt->terminal,
    GHOSTTY_MODE_BRACKETED_PASTE,
    &bracketed);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  char *input = NULL;
  if (len > 0) {
    input = malloc(len);
    if (input == NULL) {
      return GHOSTTY_OUT_OF_MEMORY;
    }
    memcpy(input, data, len);
  }

  size_t required = 0;
  result = ghostty_paste_encode(input, len, bracketed, NULL, 0, &required);
  if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
    free(input);
    return result;
  }

  if (len > 0) {
    memcpy(input, data, len);
  }

  if (required == 0) {
    free(input);
    *out = NULL;
    *out_len = 0;
    return GHOSTTY_SUCCESS;
  }

  uint8_t *buffer = ghostty_alloc(NULL, required);
  if (buffer == NULL) {
    free(input);
    return GHOSTTY_OUT_OF_MEMORY;
  }

  size_t written = 0;
  result = ghostty_paste_encode(input, len, bracketed, (char *)buffer, required, &written);
  free(input);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_free(NULL, buffer, required);
    return result;
  }

  *out = buffer;
  *out_len = written;
  return GHOSTTY_SUCCESS;
}

bool proghostty_vt_mouse_reporting_active(ProGhosttyVT *vt) {
  if (vt == NULL || vt->terminal == NULL) {
    return false;
  }
  bool tracking = false;
  return ghostty_terminal_get(
    vt->terminal,
    GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
    &tracking) == GHOSTTY_SUCCESS && tracking;
}

int proghostty_vt_scroll_ownership(ProGhosttyVT *vt, ProGhosttyVTScrollOwnership *out) {
  if (vt == NULL || vt->terminal == NULL || out == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  memset(out, 0, sizeof(*out));
  bool tracking = false;
  GhosttyResult result = ghostty_terminal_get(
    vt->terminal,
    GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
    &tracking);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  if (tracking) {
    out->kind = PROGHOSTTY_VT_SCROLL_MOUSE_REPORTING;
    return GHOSTTY_SUCCESS;
  }

  GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  if (screen != GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
    out->kind = PROGHOSTTY_VT_SCROLL_LOCAL;
    return GHOSTTY_SUCCESS;
  }

  bool alternate_scroll = false;
  result = ghostty_terminal_mode_get(vt->terminal, GHOSTTY_MODE_ALT_SCROLL, &alternate_scroll);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  if (!alternate_scroll) {
    out->kind = PROGHOSTTY_VT_SCROLL_CONSUMED;
    return GHOSTTY_SUCCESS;
  }

  bool application_cursor_keys = false;
  result = ghostty_terminal_mode_get(vt->terminal, GHOSTTY_MODE_DECCKM, &application_cursor_keys);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  out->kind = PROGHOSTTY_VT_SCROLL_ALTERNATE_CURSOR_KEYS;
  out->application_cursor_keys = application_cursor_keys;
  return GHOSTTY_SUCCESS;
}

int proghostty_vt_encode_mouse(
  ProGhosttyVT *vt,
  const ProGhosttyVTMouseEvent *event,
  const ProGhosttyVTMouseGeometry *geometry,
  uint8_t **out,
  size_t *out_len
) {
  if (out == NULL || out_len == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }
  *out = NULL;
  *out_len = 0;
  if (vt == NULL || vt->terminal == NULL || event == NULL || geometry == NULL ||
      geometry->cell_width == 0 || geometry->cell_height == 0) {
    return GHOSTTY_INVALID_VALUE;
  }

  GhosttyMouseEncoder encoder = NULL;
  GhosttyResult result = ghostty_mouse_encoder_new(NULL, &encoder);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  GhosttyMouseEvent mouse_event = NULL;
  result = ghostty_mouse_event_new(NULL, &mouse_event);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_mouse_encoder_free(encoder);
    return result;
  }

  ghostty_mouse_encoder_setopt_from_terminal(encoder, vt->terminal);
  GhosttyMouseEncoderSize size = {
    .size = sizeof(GhosttyMouseEncoderSize),
    .screen_width = geometry->screen_width,
    .screen_height = geometry->screen_height,
    .cell_width = geometry->cell_width,
    .cell_height = geometry->cell_height,
    .padding_top = geometry->padding_top,
    .padding_bottom = geometry->padding_bottom,
    .padding_right = geometry->padding_right,
    .padding_left = geometry->padding_left,
  };
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);

  ghostty_mouse_event_set_action(mouse_event, GHOSTTY_MOUSE_ACTION_PRESS);
  ghostty_mouse_event_set_button(
    mouse_event,
    event->wheel_up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE);
  GhosttyMods mods = 0;
  if (event->shift) mods |= GHOSTTY_MODS_SHIFT;
  if (event->control) mods |= GHOSTTY_MODS_CTRL;
  if (event->alt) mods |= GHOSTTY_MODS_ALT;
  ghostty_mouse_event_set_mods(mouse_event, mods);
  ghostty_mouse_event_set_position(mouse_event, (GhosttyMousePosition){
    .x = event->x,
    .y = event->y,
  });

  size_t required = 0;
  result = ghostty_mouse_encoder_encode(encoder, mouse_event, NULL, 0, &required);
  if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(encoder);
    return result;
  }
  if (required == 0) {
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(encoder);
    return GHOSTTY_SUCCESS;
  }

  uint8_t *buffer = ghostty_alloc(NULL, required);
  if (buffer == NULL) {
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(encoder);
    return GHOSTTY_OUT_OF_MEMORY;
  }
  size_t written = 0;
  result = ghostty_mouse_encoder_encode(
    encoder,
    mouse_event,
    (char *)buffer,
    required,
    &written);
  ghostty_mouse_event_free(mouse_event);
  ghostty_mouse_encoder_free(encoder);
  if (result != GHOSTTY_SUCCESS) {
    ghostty_free(NULL, buffer, required);
    return result;
  }

  *out = buffer;
  *out_len = written;
  return GHOSTTY_SUCCESS;
}

int proghostty_vt_encode_alternate_scroll(
  ProGhosttyVT *vt,
  bool wheel_up,
  size_t count,
  uint8_t **out,
  size_t *out_len
) {
  if (out == NULL || out_len == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }
  *out = NULL;
  *out_len = 0;
  if (vt == NULL || vt->terminal == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  ProGhosttyVTScrollOwnership ownership;
  GhosttyResult result = proghostty_vt_scroll_ownership(vt, &ownership);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  if (ownership.kind != PROGHOSTTY_VT_SCROLL_ALTERNATE_CURSOR_KEYS || count == 0) {
    return GHOSTTY_SUCCESS;
  }
  if (count > SIZE_MAX / 3) {
    return GHOSTTY_OUT_OF_MEMORY;
  }

  const uint8_t normal_up[] = {0x1B, '[', 'A'};
  const uint8_t normal_down[] = {0x1B, '[', 'B'};
  const uint8_t application_up[] = {0x1B, 'O', 'A'};
  const uint8_t application_down[] = {0x1B, 'O', 'B'};
  const uint8_t *sequence = ownership.application_cursor_keys
    ? (wheel_up ? application_up : application_down)
    : (wheel_up ? normal_up : normal_down);
  size_t length = count * 3;
  uint8_t *buffer = ghostty_alloc(NULL, length);
  if (buffer == NULL) {
    return GHOSTTY_OUT_OF_MEMORY;
  }
  for (size_t index = 0; index < count; index++) {
    memcpy(buffer + index * 3, sequence, 3);
  }
  *out = buffer;
  *out_len = length;
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
  cell.wide = GHOSTTY_CELL_WIDE_NARROW;
  cell.semantic_content = GHOSTTY_CELL_SEMANTIC_OUTPUT;
  cell.hyperlink_uri = NULL;
  cell.hyperlink_uri_len = 0;
  return cell;
}

static void free_cells(ProGhosttyVTCell *cells, size_t cell_count) {
  if (cells == NULL) {
    return;
  }
  for (size_t i = 0; i < cell_count; i++) {
    free(cells[i].hyperlink_uri);
    cells[i].hyperlink_uri = NULL;
    cells[i].hyperlink_uri_len = 0;
  }
  free(cells);
}

static void apply_hyperlink(ProGhosttyVTCell *cell, const GhosttyGridRef *ref) {
  if (cell == NULL || ref == NULL) {
    return;
  }

  size_t len = 0;
  GhosttyResult result = ghostty_grid_ref_hyperlink_uri(ref, NULL, 0, &len);
  if (result == GHOSTTY_SUCCESS && len == 0) {
    return;
  }
  if (result != GHOSTTY_OUT_OF_SPACE || len == 0) {
    return;
  }

  uint8_t *uri = malloc(len + 1);
  if (uri == NULL) {
    return;
  }

  size_t written = 0;
  result = ghostty_grid_ref_hyperlink_uri(ref, uri, len, &written);
  if (result != GHOSTTY_SUCCESS || written == 0) {
    free(uri);
    return;
  }
  uri[written] = 0;
  cell->hyperlink_uri = uri;
  cell->hyperlink_uri_len = written;
}

static void apply_wide(ProGhosttyVTCell *cell, GhosttyCell raw) {
  if (cell == NULL) {
    return;
  }
  GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
  if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS) {
    cell->wide = (uint8_t)wide;
  }
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
  apply_wide(&out, raw);

  GhosttyCellSemanticContent semantic = GHOSTTY_CELL_SEMANTIC_OUTPUT;
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic);
  out.semantic_content = (uint8_t)semantic;

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

  apply_hyperlink(&out, ref);
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
      GhosttyCell raw = 0;
      bool has_raw = ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS;
      if (has_raw) {
        apply_wide(cell, raw);
        GhosttyCellSemanticContent semantic = GHOSTTY_CELL_SEMANTIC_OUTPUT;
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic);
        cell->semantic_content = (uint8_t)semantic;
      }
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

      if (has_raw) {
        bool has_hyperlink = false;
        if (ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &has_hyperlink) == GHOSTTY_SUCCESS && has_hyperlink) {
          GhosttyPoint point = {
            .tag = GHOSTTY_POINT_TAG_VIEWPORT,
            .value = {.coordinate = {.x = x, .y = y}},
          };
          GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
          if (ghostty_terminal_grid_ref(vt->terminal, point, &ref) == GHOSTTY_SUCCESS) {
            apply_hyperlink(cell, &ref);
          }
        }
      }
    }
    y++;
  }

  bool cursor_visible = false;
  bool cursor_has_value = false;
  bool cursor_blinking = false;
  GhosttyTerminalScreen active_screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  GhosttyRenderStateCursorVisualStyle cursor_visual_style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  GhosttyCellSemanticContent cursor_semantic_content = GHOSTTY_CELL_SEMANTIC_OUTPUT;
  uint16_t cursor_x = 0;
  uint16_t cursor_y = 0;
  ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &cursor_blinking);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_visual_style);
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursor_has_value);
  ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_SEMANTIC_CONTENT, &cursor_semantic_content);
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
  out->cursor_semantic_content = (uint8_t)cursor_semantic_content;
  out->cells = cells_out;
  out->cell_count = cell_count;
  return GHOSTTY_SUCCESS;
}

void proghostty_vt_snapshot_free(ProGhosttyVTSnapshot *snapshot) {
  if (snapshot == NULL) {
    return;
  }
  free_cells(snapshot->cells, snapshot->cell_count);
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

  uint16_t top_request = overscan_top > PROGHOSTTY_VT_MAX_OVERSCAN_ROWS ? PROGHOSTTY_VT_MAX_OVERSCAN_ROWS : overscan_top;
  uint16_t bottom_request = overscan_bottom > PROGHOSTTY_VT_MAX_OVERSCAN_ROWS ? PROGHOSTTY_VT_MAX_OVERSCAN_ROWS : overscan_bottom;
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
  free_cells(snapshot->overscan_top_cells, snapshot->overscan_top_rows * (size_t)snapshot->viewport.cols);
  free_cells(snapshot->overscan_bottom_cells, snapshot->overscan_bottom_rows * (size_t)snapshot->viewport.cols);
  snapshot->overscan_top_cells = NULL;
  snapshot->overscan_bottom_cells = NULL;
  snapshot->overscan_top_rows = 0;
  snapshot->overscan_bottom_rows = 0;
}

int proghostty_vt_rows_at(
  ProGhosttyVT *vt,
  uint64_t start_row,
  size_t row_count,
  ProGhosttyVTRows *out
) {
  if (vt == NULL || vt->terminal == NULL || vt->render_state == NULL || out == NULL) {
    return GHOSTTY_INVALID_VALUE;
  }

  memset(out, 0, sizeof(ProGhosttyVTRows));

  // Refresh render state so cols/colors reflect the current terminal. This does
  // not move the viewport; pattern-2 browsing never scrolls the VT viewport.
  GhosttyResult result = ghostty_render_state_update(vt->render_state, vt->terminal);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  uint16_t cols = 0;
  ghostty_render_state_get(vt->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  if (cols == 0) {
    return GHOSTTY_INVALID_VALUE;
  }

  ProGhosttyVTScrollbar scrollbar = {0};
  result = proghostty_vt_scrollbar(vt, &scrollbar);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }
  uint64_t total = scrollbar.total;

  out->cols = cols;
  out->total = total;

  // Clamp the requested window into [0, total). An out-of-range request yields
  // zero rows rather than an error so callers can ask optimistically.
  if (total == 0 || row_count == 0 || start_row >= total) {
    out->start_row = start_row < total ? start_row : total;
    return GHOSTTY_SUCCESS;
  }

  uint64_t available = total - start_row;
  size_t clamped = row_count;
  if ((uint64_t)clamped > available) {
    clamped = (size_t)available;
  }
  out->start_row = start_row;

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  result = ghostty_render_state_colors_get(vt->render_state, &colors);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  ProGhosttyVTCell *cells = NULL;
  result = copy_screen_rows(vt, &colors, start_row, clamped, cols, &cells);
  if (result != GHOSTTY_SUCCESS) {
    return result;
  }

  out->cells = cells;
  out->rows = clamped;
  return GHOSTTY_SUCCESS;
}

void proghostty_vt_rows_free(ProGhosttyVTRows *rows) {
  if (rows == NULL) {
    return;
  }
  free_cells(rows->cells, rows->rows * (size_t)rows->cols);
  rows->cells = NULL;
  rows->rows = 0;
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
