import json
import time
import cv2
import numpy as np

try:
    import websocket
except Exception as e:
    raise RuntimeError("Install websocket-client: pip install websocket-client") from e

SERVER_WS_URL = "wss://metabolism-loc-kissing-spam.trycloudflare.com/ws"
CAMERA_INDEX = 0
JPEG_QUALITY = 75
TARGET_FPS = 20

def draw_detections(img, dets):
    for d in dets:
        x1, y1, x2, y2 = d["x1"], d["y1"], d["x2"], d["y2"]
        label = d.get("label", "?")
        conf = d.get("conf", 0)
        cv2.rectangle(img, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(
            img,
            f"{label} {conf:.2f}",
            (x1, max(0, y1 - 10)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (0, 255, 0),
            2,
            cv2.LINE_AA,
        )
    return img

def main():
    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        raise RuntimeError("Could not open webcam")

    ws = websocket.create_connection(
        SERVER_WS_URL,
        timeout=30,
        ping_interval=20,
        ping_timeout=10,
    )
    print("Connected to server:", SERVER_WS_URL)

    frame_id = 0
    try:
        print("trying to send frame", frame_id)
        prev = time.time()
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            ok, enc = cv2.imencode(
                ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY]
            )
            if not ok:
                continue
            jpg_bytes = enc.tobytes()

            ws.send(json.dumps({"frame_id": frame_id}))
            ws.send_binary(jpg_bytes)

            msg = ws.recv()
            resp = json.loads(msg)

            dets = resp.get("detections", [])
            vis = draw_detections(frame.copy(), dets)

            cv2.imshow("YOLO Client (local visualization)", vis)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

            frame_id += 1

            elapsed = time.time() - prev
            target = 1.0 / TARGET_FPS
            if elapsed < target:
                time.sleep(target - elapsed)
            prev = time.time()
    finally:
        ws.close()
        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
