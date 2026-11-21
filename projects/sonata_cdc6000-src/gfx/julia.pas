→ A Julia set for the Sonata's LCD (see lcd.pas for the LCD file): z := z*z + c from each pixel, c = -0.8 + 0.156 i, fixed
  point with 1024 = 1.0, 40 iterations; the colour wheel is along the bottom, under a red frame ↓

VAR LCD[OUT] : FILE OF INTEGER;
    X, Y, K, ZX, ZY, TX : INTEGER;

PROCEDURE PLOT(X, Y, C : INTEGER);
BEGIN LCD^ := C + 65536 * (X + 256 * Y); PUT(LCD) END;

FUNCTION RGB(R, G, B : INTEGER) : INTEGER;
BEGIN RGB := R * 2048 + G * 32 + B END;

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

BEGIN
  LCD^ := 4294967296; PUT(LCD);
  FOR Y := 0 TO 111 DO
    FOR X := 0 TO 159 DO
    BEGIN
      ZX := -1600 + X * 20;  ZY := -1400 + Y * 25;  K := 0;
      WHILE (K < 40) ∧ (ZX * ZX + ZY * ZY < 4194304) DO
      BEGIN
        TX := (ZX * ZX - ZY * ZY) DIV 1024 - 819;
        ZY := 2 * ZX * ZY DIV 1024 + 160;
        ZX := TX;
        K := K + 1
      END;
      IF K = 40 THEN PLOT(X, Y, RGB(0, 0, 8))
      ELSE PLOT(X, Y, RGB(K MOD 32, (K * 5) MOD 64, (K * 3) MOD 32))
    END;
  FOR X := 0 TO 159 DO
    FOR Y := 112 TO 127 DO PLOT(X, Y, HUE(X));
  FOR X := 0 TO 159 DO BEGIN PLOT(X, 0, 63488);  PLOT(X, 127, 63488) END;
  FOR Y := 0 TO 127 DO BEGIN PLOT(0, Y, 63488);  PLOT(159, Y, 63488) END
END .
