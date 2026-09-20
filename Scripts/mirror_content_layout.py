"""Reference-layout canvas for template generation; mirrors MirrorContentLayout.swift.

iPhone Mirroring keeps a fixed-point border around the phone content (38 above, 8 below,
7.5 each side), so only a 406x890 capture is proportional to the calibrated regions.
Template sources at other zoom levels are placed on a canvas with the reference
proportions before sampling, exactly as the runtime does before recognition.
"""
import numpy as np

REFERENCE_WIDTH, REFERENCE_HEIGHT = 406, 890
REFERENCE_CONTENT = (7, 38, 392, 844)  # x, y, width, height
MAXIMUM_CONTENT_ASPECT_DEVIATION = 0.012


def detect(bgr):
    """Return (top, bottom, left, right) uniform border thickness or None."""
    height, width = bgr.shape[:2]
    corner = bgr[0, 0, :3]
    row_limit, column_limit = height // 4, width // 4

    def run(lines, limit):
        count = 0
        for line in lines:
            if count >= limit or not (line[:, :3] == corner).all():
                break
            count += 1
        return count

    top = run((bgr[y] for y in range(height)), row_limit)
    bottom = run((bgr[y] for y in range(height - 1, -1, -1)), row_limit)
    left = run((bgr[:, x] for x in range(width)), column_limit)
    right = run((bgr[:, x] for x in range(width - 1, -1, -1)), column_limit)
    if min(top, bottom, left, right) == 0:
        return None
    if top >= row_limit or bottom >= row_limit or left >= column_limit or right >= column_limit:
        return None
    if abs(left - right) > 1 or abs(bottom - left) > 2 or not 4 <= top / bottom <= 5.5:
        return None
    content_width, content_height = width - left - right, height - top - bottom
    if content_width < 100 or content_height < 200:
        return None
    reference_aspect = REFERENCE_CONTENT[2] / REFERENCE_CONTENT[3]
    if abs(content_width / content_height - reference_aspect) > MAXIMUM_CONTENT_ASPECT_DEVIATION:
        return None
    return top, bottom, left, right


def canvas(bgr):
    """Place the detected content on the reference-proportioned canvas (unchanged pixels)."""
    border = detect(bgr)
    if border is None:
        raise ValueError("no mirroring border detected; the source must be a raw window capture")
    top, bottom, left, right = border
    height, width = bgr.shape[:2]
    content_width, content_height = width - left - right, height - top - bottom
    scale_x = content_width / REFERENCE_CONTENT[2]
    scale_y = content_height / REFERENCE_CONTENT[3]
    canvas_x = int(np.floor(REFERENCE_CONTENT[0] * scale_x + 0.5))
    canvas_y = int(np.floor(REFERENCE_CONTENT[1] * scale_y + 0.5))
    canvas_width = max(int(np.floor(REFERENCE_WIDTH * scale_x + 0.5)), canvas_x + content_width)
    canvas_height = max(int(np.floor(REFERENCE_HEIGHT * scale_y + 0.5)), canvas_y + content_height)
    if (canvas_width, canvas_height, canvas_x, canvas_y) == (width, height, left, top):
        return bgr
    result = np.empty((canvas_height, canvas_width, bgr.shape[2]), dtype=bgr.dtype)
    result[...] = bgr[0, 0]
    result[canvas_y:canvas_y + content_height, canvas_x:canvas_x + content_width] = \
        bgr[top:top + content_height, left:left + content_width]
    return result
