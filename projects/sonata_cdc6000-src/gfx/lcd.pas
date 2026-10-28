→ A picture for the Sonata's LCD, drawn by a Pascal program on the CDC 6000 core.

   LCD is a binary file whose words the FPGA design (cdc_lcd.v) takes for the 160x128 panel:
       LCD^ := colour + 65536 * (x + 256 * y)       plots one RGB565 pixel
       LCD^ := colour + 4294967296                  fills the panel with the colour
   Integers only: the colours are 5-6-5 bit fields, the Mandelbrot set is in fixed point (1024 = 1.0). ↓

VAR LCD[OUT] : FILE OF INTEGER;
    X, Y, K, ZX, ZY, TX, T, CX, CY : INTEGER;

PROCEDURE PLOT(X, Y, C : INTEGER);
BEGIN LCD^ := C + 65536 * (X + 256 * Y); PUT(LCD) END;

FUNCTION RGB(R, G, B : INTEGER) : INTEGER;
BEGIN RGB := R * 2048 + G * 32 + B END;

→ the colour wheel in six steps of 27 pixels ↓
FUNCTION HUE(P : INTEGER) : INTEGER;
VAR T : INTEGER;
BEGIN
  T := (P MOD 27) * 31 DIV 26;
  CASE P DIV 27 OF
    0 : HUE := RGB(31, 2 * T, 0);
    1 : HUE := RGB(31 - T, 63, 0);
    2 : HUE := RGB(0, 63, T);
    3 : HUE := RGB(0, 63 - 2 * T, 31);
    4 : HUE := RGB(T, 0, 31);
    5 : HUE := RGB(31, 0, 31 - T)
  END
END;

PROCEDURE LINE(X0, Y0, X1, Y1, C : INTEGER);
VAR DX, DY, SX, SY, DEL, E2, PX, PY : INTEGER;
BEGIN
  DX := X1 - X0; IF DX < 0 THEN DX := 0 - DX;
  DY := Y1 - Y0; IF DY < 0 THEN DY := 0 - DY;
  IF X0 < X1 THEN SX := 1 ELSE SX := 0 - 1;
  IF Y0 < Y1 THEN SY := 1 ELSE SY := 0 - 1;
  DEL := DX - DY;  PX := X0;  PY := Y0;
  PLOT(PX, PY, C);
  WHILE (PX ≠ X1) ∨ (PY ≠ Y1) DO
  BEGIN
    E2 := 2 * DEL;
    IF E2 + DY > 0 THEN BEGIN DEL := DEL - DY; PX := PX + SX END;
    IF E2 < DX THEN BEGIN DEL := DEL + DX; PY := PY + SY END;
    PLOT(PX, PY, C)
  END
END;

BEGIN
  LCD^ := RGB(0, 0, 6) + 4294967296; PUT(LCD);

  → the colour wheel along the top, and its reflection darkened below it ↓
  FOR X := 0 TO 159 DO
    FOR Y := 0 TO 15 DO PLOT(X, Y, HUE(X));

  → the Mandelbrot set, 160 x 96, 30 iterations ↓
  FOR Y := 0 TO 95 DO
    FOR X := 0 TO 159 DO
    BEGIN
      CX := -2250 + X * 19;  CY := -1200 + Y * 25;
      ZX := 0;  ZY := 0;  K := 0;
      WHILE (K < 30) ∧ (ZX * ZX + ZY * ZY < 4194304) DO
      BEGIN
        TX := (ZX * ZX - ZY * ZY) DIV 1024 + CX;
        ZY := 2 * ZX * ZY DIV 1024 + CY;
        ZX := TX;
        K := K + 1
      END;
      IF K = 30 THEN PLOT(X, Y + 16, 0)
      ELSE PLOT(X, Y + 16, RGB((K * 3) MOD 32, (K * 7) MOD 64, 31 - (K * 5) MOD 32))
    END;

  → a frame, and the diagonals of the picture ↓
  LINE(0, 0, 159, 0, 65535);  LINE(159, 0, 159, 127, 65535);
  LINE(159, 127, 0, 127, 65535);  LINE(0, 127, 0, 0, 65535);
  LINE(0, 0, 159, 127, RGB(31, 63, 0));  LINE(0, 127, 159, 0, RGB(0, 63, 31))
END .
