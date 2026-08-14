import argparse
import math
import time
from collections import defaultdict, deque

import cv2
from ultralytics import YOLO

BEARING_RATE_EPS = 0.15
SCALE_RATE_MIN = 0.35
ALERT_COOLDOWN_S = 1.5
INTERESTING_CLASS_IDS = {0, 1, 2, 3, 5, 7}

class TrackState:
    __slots__ = ("history", "last_alert_t")
    def __init__(self):
        self.history = deque(maxlen=6)
        self.last_alert_t = 0.0

def bearing(cx, cy, W, H):
    """Bearing angle in image plane relative to center; left<0, right>0."""
    nx = (cx - W / 2.0) / (W / 2.0)
    return math.atan(nx)

def size_proxy_from_box(xyxy):
    """Use sqrt(area) as a scale proxy; grows roughly linearly with image proximity."""
    x1, y1, x2, y2 = xyxy
    w = max(1.0, float(x2 - x1))
    h = max(1.0, float(y2 - y1))
    return math.sqrt(w * h)

def motion_intent_from_history(hist):
    """
    Given a short time-ordered deque of (t, cx, cy, s), compute:
    - bearing rate dβ/dt  (rad/s) using last two samples
    - relative scale rate (1/s): (s_t - s_{t-1}) / (dt * max(s_{t-1}, eps))
    """
    if len(hist) < 2:
        return None
    (t1, cx1, cy1, s1) = hist[-2]
    (t2, cx2, cy2, s2) = hist[-1]
    dt = max(1e-6, t2 - t1)
    return dt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=str, default="0", help="camera index or video file path")
    ap.add_argument("--model", type=str, default="yolov8n.pt", help="Ultralytics model path")
    ap.add_argument("--conf", type=float, default=0.25, help="detection confidence")
    ap.add_argument("--tracker", type=str, default="bytetrack.yaml", help="tracker config (Ultralytics)")
    ap.add_argument("--show", action="store_true", help="show OpenCV window")
    args = ap.parse_args()

    source = int(args.source) if args.source.isdigit() else args.source
    model = YOLO(args.model)

    tracks = defaultdict(TrackState)

    stream = model.track(
        source=source,
        conf=args.conf,
        tracker=args.tracker,
        stream=True,
        persist=True,
        verbose=False,
    )

    win = "motion-intent"
    last_global_alert_t = 0.0

    for result in stream:
        t = time.time()

        frame = result.orig_img if hasattr(result, "orig_img") else None
        H, W = (frame.shape[0], frame.shape[1]) if frame is not None else (1080, 1920)

        boxes = result.boxes
        if boxes is None or boxes.xyxy is None:
            if args.show and frame is not None:
                cv2.imshow(win, frame)
                if cv2.waitKey(1) == 27:
                    break
            continue

        xyxy = boxes.xyxy.cpu().numpy()
        cls = boxes.cls.cpu().numpy().astype(int) if boxes.cls is not None else []
        ids = boxes.id.cpu().numpy().astype(int) if boxes.id is not None else [-1] * len(xyxy)
        confs = boxes.conf.cpu().numpy() if boxes.conf is not None else []

        for k, (bb, c, track_id) in enumerate(zip(xyxy, cls, ids)):
            if track_id < 0 or c not in INTERESTING_CLASS_IDS:
                continue
            x1, y1, x2, y2 = bb
            cx = 0.5 * (x1 + x2)
            cy = 0.5 * (y1 + y2)
            s = size_proxy_from_box(bb)
            st = tracks[track_id]
            st.history.append((t, cx, cy, s))

        best_left = (-1, -1.0, None)
        best_right = (-1, -1.0, None)

        for k, (bb, c, track_id) in enumerate(zip(xyxy, cls, ids)):
            if track_id < 0 or c not in INTERESTING_CLASS_IDS:
                continue
            st = tracks[track_id]
            hist = st.history
            if len(hist) < 2:
                continue

            (_, cx1, cy1, s1) = hist[-2]
            (_, cx2, cy2, s2) = hist[-1]
            dt = max(1e-3, hist[-1][0] - hist[-2][0])

            b1 = bearing(cx1, cy1, W, H)
            b2 = bearing(cx2, cy2, W, H)
            bdot = (b2 - b1) / dt

            sdot_rel = (s2 - s1) / (max(s1, 1e-3) * dt)

            const_bearing = max(0.0, (BEARING_RATE_EPS - abs(bdot)) / BEARING_RATE_EPS)
            growth = max(0.0, sdot_rel / SCALE_RATE_MIN)
            risk = 0.6 * const_bearing + 0.4 * min(2.0, growth)

            b_now = b2
            side = "left" if b_now < 0 else "right"

            if side == "left" and risk > best_left[1]:
                best_left = (track_id, risk, bb)
            elif side == "right" and risk > best_right[1]:
                best_right = (track_id, risk, bb)

            if frame is not None:
                color = (0, 255, 0) if risk < 0.7 else (0, 165, 255) if risk < 1.0 else (0, 0, 255)
                x1, y1, x2, y2 = map(int, bb)
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                cv2.putText(frame,
                            f"id {track_id} r={risk:.2f} b'={bdot:.2f} s'={sdot_rel:.2f}",
                            (x1, max(15, y1 - 8)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1, cv2.LINE_AA)

        now = t
        for (side, best) in (("LEFT", best_left), ("RIGHT", best_right)):
            track_id, risk, bb = best
            if track_id >= 0 and risk >= 1.0:
                st = tracks[track_id]
                if now - st.last_alert_t >= ALERT_COOLDOWN_S:
                    print(f"[ALERT] {side} APPROACH — track {track_id}  risk={risk:.2f}")
                    st.last_alert_t = now
                    last_global_alert_t = now
                if frame is not None:
                    banner = f"{side} APPROACH"
                    cv2.putText(frame, banner, (10, 30 if side == "LEFT" else 60),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)

        if args.show and frame is not None:
            cv2.imshow(win, frame)
            if cv2.waitKey(1) == 27:
                break

    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
