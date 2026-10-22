→DECK PASCSYM↓
→****************************************************************
 *                                                               *
 *                      PASCAL COMPILER                          *
 *                                                               *
 *                         20/06/72                              *
 *                                                               *
 *   AUTHORS:  U. AMMANN,  R. SCHILD                             *
 *                                                               *
 *           FACHGRUPPE COMPUTERWISSENSCHAFTEN                   *
 *           EIDG. TECHNISCHE HOCHSCHULE                         *
 *           CH-8006 ZUERICH                                     *
 *                                                               *
 ****************************************************************↓

→$T-,O+,R+   COMPILE WITH STACK OVERFLOW TEST AND
              ROUNDING INSTRUCTIONS↓

CONST NOP = 46000B, NILVAL = 200000B,
   JMPCST = 61650000004000000000B, EQJMP = 04000000004600046000B,
   MAX10 = 3146314631463146313B, MASK = -777777B,
   MAXLABS = 20, MAXEXLABS = 10, JMPMAX = 49,
   CSTMAX = 40, CODMAX = 1000, UNDMAX = 70,
   DISPLIMIT = 20, PTLIMIT = 10, FILLIMIT = 10,
   MAXLEVEL = 7,
   → DONT INCREASE WITHOUT INCREASING UPPER BOUND OF RG3 TOO ↓
   WORDLENGTH = 60,

   PROCDR = -1, OBJ = +1, →FOR PMDFILE↓

   GETC = 101B, PUTC = 103B,
   →ADDRESSES OF RESIDENT STANDARD ROUTINES↓

   ASSERR = 170B, INXERR = 171B, DIVERR = 172B, STOFLERR = 174B,
   →RUNTIME ERROR EXITS↓

   INPT = 212B, OUTPT = 233B;
   → ADDRESSES OF STANDARD FILES INPUT AND OUTPUT ↓

TYPE CTP = ^CONTEXTTABLE;
   CWORD = ARRAY [1..10] OF CHAR;
   ADDRESS = 0..177777B ;
   SHRTINT = -377777B .. +377777B;
   BITRANGE = 0 .. 60; RG3 = 0 .. 7;
   ATTRKIND = (VARBL,SVAL,LVAL,LCOND);
   ATTR = RECORD TYPTR : CTP ;
             CASE KIND : ATTRKIND OF
                VARBL: (ACCESS : (DRCT,INDRCT,INXD) ;
                        BREG : RG3 ; DPLMT : SHRTINT ;
                        CASE PCKD : BOOLEAN OF
                           FALSE: ;
                           TRUE: (BITADR, BITSZ : BITRANGE)) ;
                SVAL: (VAL : SHRTINT) ;
                LVAL: (CTERM : SHRTINT) ;
                LCOND: (JMP : 0 .. 3 ; ARITH : BOOLEAN)
          END ;
   →DESCRIBES EXPRESSIONS TO BE COMPILED.   EXAMPLES:
      VARBL:      DRCT:                I                    **
                  INDRCT:              INPUT^                *
                  INXD:                A[K]                  *
      SVAL:                            4                    **
      LVAL:                            2*I - 1               *
      LCOND:      ARITH:               X >= 4.1              *
                  NOT ARITH:           B < TRUE              *

      *  RESULT OF CODEGENERATION IN REGISTER X-RP
      ** NO CODE GENERATION UNTIL NOW↓


   OPTPWR = (NOOPT,PUREP,POSP,NEGP);
   IDCLASS = (TYPES,KONST,PROC,VARS,FIELD,TAGFIELD,DUMMYCLASS);
   TYPFORM = (NUMERIC,SYMBOLIC,POINTER,POWER,
              ARRAYS,RECORDS,CLASSS,FILES);
   IDKINDS = (ACTUAL,FORMAL);
   WHERE = (BLOCK,CWITH,VWITH);
   PKINDS = PROCDR .. OBJ; →FOR PMDFILE↓

VAR PARMLIST : RECORD    ICO : ADDRESS ;
                         ERRFLAG : BOOLEAN ;
                         ERRNRS : ARRAY [0..3] OF POWERSET 0..31 ;
                         LOADPT : ADDRESS ;
                         LIMCODE : ADDRESS ;
                         LPJMPTAB : ADDRESS ;
                         EXTFLAGS : POWERSET 0..4 ;
                         ENTRYPT : ADDRESS
               END ;
   JMPTAB : ARRAY [0..JMPMAX] OF INTEGER;
   JMPIX : SHRTINT;
   →TRANSFER VECTOR FOR CALLS OF FORWARD DECLARED PROCEDURES AND
    GOTO STATEMENTS LEADING OUT OF PROCEDURES↓

   CSTTB : ARRAY [1..CSTMAX] OF
      RECORD VALU : INTEGER; INX : SHRTINT  END;
   LCX : SHRTINT;
   →CONTAINS ALL CONSTANTS C, ABS(INT(C)) >= 2**17, OCCURRING IN THE
    PROCEDURE ACTUALLY BEING COMPILED TOGETHER WITH AN INDEX INTO
    UNDLAB WHERE THEIR OCCURRENCES IN THE CODE OF THIS PROCEDURE
    ARE CHAINED↓

   PILEV,FILEV : ARRAY [0..MAXLEVEL] OF SHRTINT;
   PFL : ARRAY[0..FILLIMIT] OF ADDRESS;
   FILPTS : ARRAY [0..FILLIMIT] OF CTP;
   PFTOP,FILTOP : SHRTINT;
   →PFL CONTAINS THE ADDRESSES OF LOCAL CLASSES,
      PILEV CONTAINS POINTERS INTO PFL, PFTOP = TOP OF PFL.
    FILPTS CONTAINS POINTERS TO ENTRIES FOR LOCAL FILES,
      FILEV CONTAINS POINTERS INTO FILPTS, FILTOP = TOP OF FILPTS↓

   EXTAB : ARRAY [1..MAXEXLABS] OF
      PACKED RECORD EXVAL,JMPTABIX : SHRTINT END;
   CEXTABIX : SHRTINT;
   →CONTAINS THE EXPLICITLY DECLARED LABELS OF ALL PROCEDURES
    NOT YET CLOSED, TOGETHER WITH THEIR CORRESPONDING INDEX
    INTO JMPTAB↓

   LABTAB : ARRAY [1..MAXLABS] OF
      PACKED RECORD LABVAL,FLD2,FLD3 : SHRTINT  END;
   CLABIX : SHRTINT;
   →CONTAINS ALL LABELS MET SO FAR IN THE BODY OF THE PROCEDURE
    ACTUALLY BEING COMPILED, TOGETHER WITH INFORMATION WHETHER
    LABEL DEFINITION (<LABEL>:) ALREADY FOUND OR NOT (FLD2).
    IN THE FORMER CASE FLD3 CONTAINS THE CORRESPONDING ADDRESS,
    WHERE IN THE LATTER CASE FLD3 CONTAINS AN INDEX INTO UNDLAB
    WHERE THE OCCURRENCES ARE CHAINED↓

   UNDLAB : ARRAY [1..UNDMAX] OF
      PACKED RECORD SUCC, PLACE : SHRTINT ;
                    LFTSH : BITRANGE ;
               END ;
   CHNIX : SHRTINT;
   →ACTS AS LISTSTRUCTURE, CHAINING OCCURRENCES OF CONSTANTS AND
    JUMPS TO NOT YET REACHED LABELS IN THE CODE OF THE PROCEDURE
    ACTUALLY BEING COMPILED.
    CHNIX = HEAD OF FREE LIST↓

   PTLIST : ARRAY [0..PTLIMIT] OF
      RECORD HNAME : ALFA; PPTR : CTP END;
   PTX : SHRTINT;
   →PTLIST CONTAINS NAMES OF YET UNDECLARED CLASSES AND
      POINTERS TO THE CORRESPONDING POINTER-TYPE ENTRIES
    PTX = TOP OF PTLIST ↓

   ERRLIST : ARRAY [1..10] OF
      PACKED RECORD POS,NMR : SHRTINT  END;
   ERRINX,CHCNT : SHRTINT; EOLFLAG,ERR : BOOLEAN;
   →ERRLIST CONTAINS THE POSITIONS AND NUMBERS OF THE ERRORS
      ON ONE LINE
      ERRINX = TOP OF ERRLIST
      CHCNT = POSITION OF LAST READ CHARACTER
    ERRLIST,ERRINX,CHCNT,EOLFLAG ARE USED BY NEXTCH
      AND ERROR.
    ERR IS SET WHENEVER ERROR HAS BEEN CALLED AND IS TESTED
      (AND RESET) BY SEVERAL PROCEDURES ↓

   DISPLAY : ARRAY [0..DISPLIMIT] OF
   PACKED RECORD FNAME : CTP;
        CASE OCCUR : WHERE OF
            BLOCK : ;
            CWITH : (CDSPL : SHRTINT; CLEV : RG3);
            VWITH : (VDSPL : SHRTINT);
   END;
   TOP,DISX : SHRTINT;
   →TOP = TOP OF DISPLAY, DISX IS RETURNED BY SEARCH↓

   CODE : ARRAY [0..CODMAX] OF INTEGER;
   CA,CP : SHRTINT;  BUF : INTEGER;
   PASCLGO[OUT] : FILE OF INTEGER;
   →CODE IS WRITTEN ONTO PASCLGO.
    BUF IS THE CURRENT ELEMENT OF CODE.
    CA = INDEX TO CODE, CP = NUMBER OF QUARTER-WORDS USED ↓
   LASTOP, LASTI : SHRTINT ;  →TO AVOID B XI XJ - INSTRUCTIONS↓

   PMDFILE[OUT]: FILE 1 OF
      PACKED RECORD PNAME : ALFA;
         CASE PKIND : PKINDS OF
         OBJ: (ACCESS,TYP,RLA : SHRTINT);
         PROCDR: (LINK,SA,COUNT : SHRTINT);
      END;
   PMCTR,LASTLINK : SHRTINT;

   LC,IC : ADDRESS;
   →LOCATION COUNTER AND INSTRUCTION COUNTER↓

   LEVEL,RP,RP1 : RG3;
   →RP,RP1 = REGISTER-POINTERS (STACK OF X-REGS)↓
   DP : BOOLEAN ;
   →DP = TRUE : DECLARATION PART (USED BY NEXTCH)↓

   PRCODE,ASSCHECK,INXCHECK,DIVCHECK,STOFLCHECK,
   ROUNDING : BOOLEAN ;  →COMPILER OPTIONS↓

   GATTR : ATTR;  →GLOBAL ATTRIBUTE RECORD ↓

   CONTEXTTABLE : CLASS 450 OF
   PACKED RECORD
   NAME : ALFA;  NXTEL : CTP;
      CASE KLASS : IDCLASS OF
      TYPES : (SIZE : SHRTINT;
         CASE FORM : TYPFORM OF
            NUMERIC : (BITS : BITRANGE; MIN,MAX : INTEGER);
            SYMBOLIC : (FCONST,PWSET : CTP; BITSIZE : BITRANGE);
            POINTER : (DOMAIN,ELTYPE : CTP);
            POWER : (ELSET : CTP; PWBITS : BITRANGE);
            ARRAYS : (AELTYPE,INXTYPE : CTP;  LO,HI : SHRTINT;
               OPTTYP : OPTPWR; EXP1,EXP2 : BITRANGE);
            RECORDS : (FSTFLD,RECVAR : CTP);
            CLASSS : (PELTYPE : CTP);
            FILES : (FELTYPE : CTP)   );
      KONST : (CONTYPE : CTP;
         CASE CONKIND : IDKINDS OF
         ACTUAL : (SUCC : CTP; VALUES : INTEGER);
         FORMAL : (CADDR : ADDRESS; CLEVEL : RG3)   );
      PROC : (PROCTYPE,FORMALS : CTP;
         PROCKIND : IDKINDS;
         PROCADDR : ADDRESS; PROCLEVEL : RG3;
         SEGSIZE : SHRTINT);
      VARS : (VTYPE : CTP; VKIND : IDKINDS;
         VADDR : ADDRESS; VLEVEL : RG3);
      FIELD : (FLDTYPE : CTP; FLDADDR : ADDRESS;
         BITDISPL,BITWIDTH : BITRANGE);
      TAGFIELD : (CASESIZE : SHRTINT; VARIANTS : CTP;
         CASE TAGVAL : BOOLEAN OF
         FALSE : (CASETYPE : CTP);
         TRUE : (CASEVAL : INTEGER)   );
   END;

   INTPTR,REALPTR,ALFAPTR,CHARPTR,BOOLPTR,PREDEFP,NILPTR,
      UNDECPTR,PNUMPTR,EXTPTR,LAMPTR : CTP; →CONSTANT POINTERS↓

   NEXT,CTPTR,MAXCTP : CTP;
   →VARIABLES POINTING INTO CONTEXTTABLE↓

   CH : CHAR; AVAL : ALFA; IVAL : INTEGER; A : CWORD;
   NO,CL : SHRTINT;
   →CH IS OUTPUT BY NEXTCH AND USED BY INSYMBOL.
      AVAL/IVAL, NO, CL  ARE OUTPUT BY INSYMBOL↓

   TCT,TMAX,B6DPL,KK : SHRTINT ;
   PT : CTP; IT,IT1 : INTEGER;
   →AUXILIARY VARIABLES, USED IN MAIN PGM AND SEVERAL PROCEDURES↓

   DIGITS : POWERSET CHAR ;
   →0: SIN/COS, 1: EXP, 2: LN, 3: SQRT, 4: ARCTAN↓

   →CONSTANTS AND CONSTANT TABLES: ↓
   TWOTO17 : INTEGER;
   SPLITSTAT : ARRAY [0..48] OF SHRTINT;
   ERRCL,TERRCL : ARRAY [0..48] OF (IRRELSY,BEGSY,ENDSY);
   BLANK : ALFA;
   WD : ARRAY [0..32] OF ALFA;
   WNO,WCL : ARRAY [0..32] OF SHRTINT;
   WL : ARRAY [0..11] OF SHRTINT;
   → WD = WORD DELIMITERS
    WNO,WCL = CORRESPONDING VALUES OF  NO  AND  CL
    WORD DELIMITERS OF LENGTH  I  START IN WD[WL[I]]  ↓
   SYMNO,SYMCL : ARRAY [≡+≡..≡;≡] OF SHRTINT;
   →NO AND CL OF EACH CHARACTER↓
   JB1,JB2,JX1,JX2,REL,FS,R1 : ARRAY [0..7] OF CHAR;
   SH : ARRAY [12..23] OF CHAR;
   →ARRAYS JB1 ... SH ARE USED BY PRTCOMP↓
   INITNAM : ARRAY [-1..37] OF ALFA;
   →CONTAINS THE PREDEFINED IDENTIFIERS,
      USED FOR INITIALIZING THE CONTEXT TABLE↓

   → ------------------------------------------------------------------ ↓

   → VARIABLE INITIALIZATIONS ↓
   VALUE
      TWOTO17 = 400000B ;
      SPLITSTAT = (1,2,19*1,3,1,4,1,1,5,1,6,1,7,1,8,2*1,9,12*1,10) ;
      ERRCL = (16*IRRELSY,ENDSY,4*IRRELSY,BEGSY,ENDSY,BEGSY,IRRELSY,
              ENDSY,BEGSY,IRRELSY,BEGSY,ENDSY,BEGSY,IRRELSY,BEGSY,
              2*IRRELSY,BEGSY,IRRELSY,ENDSY,2*IRRELSY,2*ENDSY,
              IRRELSY,3*ENDSY,2*IRRELSY,BEGSY);
      TERRCL = (9*IRRELSY,BEGSY,ENDSY,IRRELSY,ENDSY,3*IRRELSY,
         ENDSY,IRRELSY,BEGSY,2*IRRELSY,3*ENDSY,2*IRRELSY,ENDSY,
         IRRELSY,ENDSY,IRRELSY,ENDSY,IRRELSY,ENDSY,2*IRRELSY,
         ENDSY,IRRELSY,ENDSY,BEGSY,IRRELSY,2*ENDSY,IRRELSY,
         3*ENDSY,2*IRRELSY,ENDSY);
      BLANK = ≡          ≡ ;
      WD = (≡IF≡,≡DO≡,≡TO≡,≡OF≡,≡IN≡,
         ≡END≡,≡NIL≡,≡FOR≡,≡DIV≡,≡MOD≡,≡VAR≡,
         ≡THEN≡,≡ELSE≡,≡GOTO≡,≡CASE≡,≡WITH≡,≡TYPE≡,≡FILE≡,
         ≡BEGIN≡,≡UNTIL≡,≡WHILE≡,≡ARRAY≡,≡VALUE≡,≡CLASS≡,
            ≡CONST≡,≡LABEL≡,
         ≡REPEAT≡,≡DOWNTO≡,≡RECORD≡,≡PACKED≡,
         ≡FUNCTION≡,≡POWERSET≡,≡PROCEDURE≡);
      WNO = (23,31,33,27,8,
         22,36,32,6,6,43,
         24,25,35,26,48,37,38,
         21,29,30,38,47,38,41,40,
         28,33,38,42,
         44,38,45);
      WCL = (0,0,1,0,7,
         0,0,0,4,5,0,
         6*0,3,
         0,0,0,1,0,4,0,0,
         0,2,2,0,
         0,5,0);
      WL = (0,0,0,5,11,18,26,30,30,32,33,33);
      SYMNO = (7,7,6,6,9,10,4,8,0,15,17,0,11,12,
         19,8,13,7,6,18,14,8,8,8,8,5,16);
      SYMCL = (1,2,1,2,0,0,1,6,3,0,0,2,0,0,
         0,5,0,3,3,0,0,1,4,2,3,1,0);
      JB1 = (≡P≡,≡R≡,≡J≡,≡ ≡,≡E≡,≡N≡,≡G≡,≡L≡);
      JB2 = (≡S≡,≡J≡,≡P≡,≡ ≡,≡Q≡,≡E≡,≡E≡,≡T≡);
      JX1 = (≡Z≡,≡N≡,≡P≡,≡N≡,≡I≡,≡O≡,≡D≡,≡I≡);
      JX2 = (≡R≡,≡Z≡,≡L≡,≡G≡,≡R≡,≡R≡,≡F≡,≡D≡);
      REL = (≡ ≡,≡∧≡,≡∨≡,≡-≡,≡=≡,≡≠≡,≡≥≡,≡≤≡);
      FS  = (≡F≡,≡R≡,≡D≡,≡ ≡,≡ ≡,≡A≡,≡B≡,≡X≡);
      R1  = (≡A≡,≡B≡,≡X≡,≡X≡,≡A≡,≡A≡,≡B≡,≡B≡);
      SH  = (≡F≡,≡D≡,≡R≡,≡I≡,≡L≡,≡A≡,≡L≡,≡A≡,≡N≡,≡Z≡,≡U≡,≡P≡);
      INITNAM = (≡TEXT≡,≡WEOR≡,≡GET≡,≡PUT≡,≡RESET≡,≡ALLOC≡,
         ≡PACK≡,≡UNPACK≡,≡INSERT≡,≡APPEND≡,
         ≡READ≡,≡WRITE≡,
         ≡ODD≡,≡INT≡,≡CHR≡,≡EOF≡,≡ABS≡,≡SQR≡,
         ≡TRUNC≡,≡PRED≡,≡SUCC≡,≡EOL≡,≡ALFALENG≡,
         ≡INPUT≡,≡OUTPUT≡,≡ALFA≡,≡REAL≡,≡CHAR≡,≡BOOLEAN≡,
         ≡FALSE≡,≡TRUE≡,≡INTEGER≡,≡ ≡,
         ≡SIN≡,≡COS≡,≡EXP≡,≡LN≡,≡SQRT≡,≡ARCTAN≡) ;

   →TWO STANDARD PROCEDURES  INSERT  AND  APPEND  ARE PROVIDED FOR
      CODE GENERATION.
    APPEND(A,B,C) SHIFTS THE CONTENTS OF A LEFT B BITS AND
      'OR'S C INTO IT. RESULT IN A. B,C UNCHANGED.
    INSERT(A,B,C) SHIFTS THE CONTENTS OF A LEFT B BITS AND
      'OR'S THEM INTO C. RESULT IN C. A,B UNCHANGED
    A,B,C ARE OF TYPE INTEGER  ↓


PROCEDURE PRTERR ;
   VAR LASTPOS,FREEPOS,CURRPOS,CURRNMR,F,K : SHRTINT ;
BEGIN WRITE(≡ ****  ≡ : 7) ;
   LASTPOS := 0 ; FREEPOS := 1 ;
   FOR K := 1 TO ERRINX DO
   BEGIN WITH ERRLIST[K] DO
      BEGIN CURRPOS := POS ; CURRNMR := NMR END ;
      IF CURRPOS = LASTPOS THEN WRITE(≡,≡) ELSE
      BEGIN WHILE FREEPOS < CURRPOS DO
         BEGIN WRITE(≡ ≡) ;
            FREEPOS := FREEPOS + 1
         END ;
         WRITE(≡^≡) ;
         LASTPOS := CURRPOS
      END ;
      IF CURRNMR < 10 THEN F := 1 ELSE
      IF CURRNMR < 100 THEN F := 2 ELSE F := 3 ;
      WRITE(CURRNMR : F) ;
      FREEPOS := FREEPOS + F + 1 ;
   END ;
   WRITE(EOL) ; ERRINX := 0
END →PRTERR↓ ;

PROCEDURE NEXTCH;
   →READS NEXT CHAR OF FILE INPUT,
    CONVERTS EOL TO BLANK,
    PRINTS ERROR SUMMARY AFTER EACH LINE (IF ERRORS PRESENT)
    AND PRINTS ADDRESS AT BEGINNING OF LINE ↓
BEGIN
   IF EOLFLAG THEN
   BEGIN IF ERRINX > 0 THEN →PRINT ERRORS↓ PRTERR;
      EOLFLAG := FALSE;  CHCNT := 0;
      OUTPUT^ := ≡ ≡; PUT(OUTPUT);
      IF DP THEN WRITE(LC : 6 OCT) ELSE WRITE(IC : 6 OCT) ;
      OUTPUT^ := ≡ ≡;  PUT(OUTPUT);
   END →EOLFLAG↓;
   GET(INPUT); CH := INPUT^;
   OUTPUT^ := CH; PUT(OUTPUT); CHCNT := CHCNT + 1;
   IF CH = EOL THEN
   BEGIN CH := ≡ ≡;  EOLFLAG := TRUE  END;
END →NEXTCH↓;

PROCEDURE ERROR(I:SHRTINT);
BEGIN ERR := TRUE ;
   WITH PARMLIST DO
   BEGIN ERRFLAG := TRUE ;
      ERRNRS[I DIV 32] := ERRNRS[I DIV 32] ∨ [I MOD 32]
   END ;
   IF ERRINX ≥ 9 THEN
   BEGIN ERRLIST[10].NMR := 104 ; ERRINX := 10 ;
      WITH PARMLIST DO
      ERRNRS[3] := ERRNRS[3] ∨ [8] ;
   END ELSE
   BEGIN ERRINX := ERRINX + 1 ;
      ERRLIST[ERRINX].NMR := I
   END ;
   ERRLIST[ERRINX].POS := CHCNT
END →ERROR↓;

→ ------------------------------------------------------------------ ↓

→ I N S Y M B O L          READS ONE PASCAL-SYMBOL  ↓
→ LIST OF SYMBOL NUMBERS
 NO   CL   SYMBOL                  NO   CL   SYMBOL

  1        ID                      20        :=
  2    1   INTEGER CONST           21        BEGIN
  2    2   REAL    CONST           22        END
  2    3   ALFA    CONST           23        IF
  2    4   CHAR    CONST           24        THEN
                                   25        ELSE
                                   26        CASE
  5    1   NOT                     27        OF
  6    1   *                       28        REPEAT
  6    2   /                       29        UNTIL
  6    3   ^                       30        WHILE
  6    4   DIV                     31        DO
  6    5   MOD                     32        FOR
  7    1   +                       33   1    TO
  7    2   -                       33   2    DOWNTO
  7    3   V                       35        GOTO
  8    1   <                       36        NIL
  8    2   <=                      37        TYPE
  8    3   >=                      38   1    ARRAY
  8    4   >                       38   2    RECORD
  8    5   <>                      38   3    FILE
  8    6   =                       38   4    CLASS
  8    7   IN                      38   5    POWERSET
  9        (                       40        LABEL
 10        )                       41        CONST
 11        [                       42        PACKED
 12        ]                       43        VAR
 15        ,                       44        FUNCTION
 16        ;                       45        PROCEDURE
 17        .                       47        VALUE
 18        ^                       48        WITH
 19        :

 NOT PASCAL SYMBOLS : BLANK  '  (*  $  ↓

PROCEDURE INSYMBOL;
   VAR SCALE,EXP : SHRTINT;  R,FAC,RVAL : REAL;
      DIGIT : ARRAY[0..19] OF SHRTINT;
            →FOR WORDLENGTH DIV 3 = 20 DIGITS↓
      I,K : SHRTINT;  BT1,SIGN : BOOLEAN;
      AA : ALFA; CH1 : CHAR;

BEGIN
1: WHILE CH=≡ ≡ DO NEXTCH;
   IF CH ≤ ≡Z≡ THEN
   BEGIN → READ IDENTIFIER OR WORD DELIMITER ↓
      K := 0;
      REPEAT IF K < ALFALENG THEN
         BEGIN K := K + 1;  A[K] := CH END;
         NEXTCH;
      UNTIL CH >≡9≡;
      IF K ≥ KK THEN KK := K ELSE
      REPEAT A[KK] := ≡ ≡ ; KK := KK - 1 UNTIL KK = K ;
      PACK(A,1,AA);
      → TEST FOR WORD DELIMITER ↓
      FOR I := WL[K] TO WL[K+1]-1 DO
         IF AA = WD[I] THEN
         BEGIN NO := WNO[I];  CL := WCL[I];
            IVAL := 0;  GOTO 2;
         END;
      → IDENTIFIER ↓
      NO := 1;  CL := K;  AVAL := AA;
2: END →LETTER↓ ELSE
   IF CH ≤ ≡9≡ THEN
   BEGIN NO := 2; CL := 1; I := 0;
      WHILE CH IN DIGITS DO
      BEGIN IF I < 20 →20 = WORDLENGTH DIV 3↓ THEN
         DIGIT[I] := INT(CH) - INT(≡0≡);
         I := I + 1; NEXTCH
      END;
      IVAL := 0;
      IF CH = ≡B≡ THEN →OCTAL↓
      BEGIN IF I > 20 THEN ERROR(2) ELSE
         FOR K := 0 TO I-1 DO IVAL := 8*IVAL + DIGIT[K];
         NEXTCH
      END →OCTAL↓ ELSE
      BEGIN IF I > 17 THEN ERROR(2) ELSE
         FOR K := 0 TO I - 1 DO
            BEGIN IF IVAL ≤ MAX10 THEN
               IVAL := 10*IVAL + DIGIT[K] ELSE
               BEGIN ERROR(2); IVAL := 0; GOTO 40 END
            END;
40:         SCALE := 0;
            IF CH = ≡.≡ THEN
            BEGIN NEXTCH; IF CH = ≡.≡ THEN CH := ≡:≡ ELSE
               BEGIN RVAL := IVAL; CL := 2;
                  IF ¬(CH IN DIGITS) THEN ERROR(3) ELSE
                  REPEAT R := INT(CH) - INT(≡0≡);
                     RVAL := 10.0*RVAL + R;
                     SCALE := SCALE - 1; NEXTCH
                  UNTIL ¬(CH IN DIGITS);
               END;
            END;
            IF CH = ≡E≡ THEN
            BEGIN IF SCALE = 0 THEN
               BEGIN RVAL := IVAL; CL := 2
               END;
               SIGN := FALSE; NEXTCH;
               IF CH = ≡+≡ THEN NEXTCH ELSE
               IF CH = ≡-≡ THEN
                  BEGIN NEXTCH; SIGN := TRUE
                  END;
               EXP := 0;
               WHILE CH IN DIGITS DO
               BEGIN EXP := 10*EXP + (INT(CH) - INT(≡0≡));
                  NEXTCH
               END;
               IF SIGN THEN EXP := -EXP;
               SCALE := SCALE + EXP
            END;
            IF SCALE ≠ 0 THEN
            BEGIN R := 1.0;
               IF SCALE < 0 THEN BEGIN FAC := 0.1; SCALE := -SCALE END
                              ELSE FAC := 10.0;
               REPEAT IF ODD(SCALE) THEN R := R*FAC;
               FAC := SQR(FAC); SCALE := SCALE DIV 2
            UNTIL SCALE = 0; →R = 10 ** SCALE↓
            RVAL := RVAL*R
         END;
         IF CL = 2 THEN IVAL := INT(RVAL)
      END →NOT OCTAL↓
   END →NUMBER↓ ELSE
   BEGIN → SPECIAL CHARACTER ↓
      IF CH = ≡≡≡≡ THEN → ALFA OR CHAR CONSTANT ↓
      BEGIN NO := 2; K := 0; BT1 := FALSE;
         REPEAT NEXTCH;
            IF CH = ≡≡≡≡ THEN
            BEGIN NEXTCH; BT1 := CH ≠ ≡≡≡≡ END;
            IF ¬ BT1 THEN
               IF K = ALFALENG THEN
               BEGIN ERROR(3); BT1 := TRUE END ELSE
               BEGIN K := K + 1; A[K] := CH END;
         UNTIL BT1;
         IF K =1 THEN → CHAR CONST ↓
         BEGIN CL:=4; IVAL:= INT (A[1]) END
         ELSE → ALFA CONST ↓
         BEGIN IF K ≥ KK THEN KK := K ELSE
            REPEAT A[KK] := ≡ ≡; KK := KK - 1 UNTIL KK = K ;
            PACK (A,1,AA);
            CL:=3; IVAL:= INT(AA) ;
         END;
      END → ' ↓ ELSE
      BEGIN NO:= SYMNO[CH]; CL:=SYMCL[CH]; IVAL:=0;
         → TEST FOR TWO-CHARACTER SYMBOL ↓
         IF CH = ≡:≡ THEN
         BEGIN NEXTCH;
            IF CH=≡=≡ THEN
            BEGIN NO:= 20; NEXTCH END;
         END ELSE
         IF CH =≡.≡ THEN
         BEGIN NEXTCH;
            IF CH = ≡.≡ THEN → : ↓
            BEGIN NO:=19; NEXTCH END;
         END ELSE
         IF CH = ≡→≡ THEN → SKIP COMMENT ↓
         BEGIN NEXTCH;
            IF CH = ≡$≡ THEN
            REPEAT NEXTCH ;
            IF CH ≠ ≡↓≡ THEN
            BEGIN CH1 := CH ; NEXTCH ;
               IF CH1 = ≡A≡ THEN ASSCHECK := CH = ≡+≡ ELSE
               IF CH1 = ≡C≡ THEN PRCODE := CH = ≡+≡ ELSE
               IF CH1 = ≡D≡ THEN DIVCHECK := CH = ≡+≡ ELSE
               IF CH1 = ≡O≡ THEN STOFLCHECK := CH = ≡+≡ ELSE
               IF CH1 = ≡R≡ THEN ROUNDING := CH = ≡+≡ ELSE
               IF CH1 = ≡T≡ THEN
               BEGIN ASSCHECK := CH = ≡+≡ ;
                  DIVCHECK := CH = ≡+≡ ; STOFLCHECK := CH = ≡+≡ ;
                  ROUNDING := CH = ≡+≡ ; INXCHECK := CH = ≡+≡
               END ELSE
               IF CH1 = ≡X≡ THEN INXCHECK := CH = ≡+≡ ;
               IF CH ≠ ≡↓≡ THEN NEXTCH
            END ;
            UNTIL CH ≠ ≡,≡ ;
            WHILE CH ≠ ≡↓≡ DO NEXTCH;
            NEXTCH; GOTO 1 ;
         END ELSE
         NEXTCH;
      END → SPECIAL CHARACTER ↓ ;
   END;
END → INSYMBOL ↓ ;

→ ------------------------------------------------------------------ ↓

PROCEDURE SRCHREC(P:CTP);
   → SEARCHES ONE BLOCK, RETURNS CTPTR ↓
BEGIN CTPTR := P;
   WHILE CTPTR ≠ NIL DO
      IF CTPTR^.NAME = AVAL THEN GOTO 1
      ELSE CTPTR := CTPTR^.NXTEL;
1:END → SRCHREC ↓ ;

PROCEDURE SEARCH;
   → SEARCHES CONTEXTTABLE, RETURNS CTPTR AND DISX = INDEX TO
      DISPLAY ↓
   VAR I : SHRTINT;
BEGIN FOR I := TOP DOWNTO 0 DO
   BEGIN CTPTR := DISPLAY[I].FNAME;
      WHILE CTPTR ≠ NIL DO
         IF CTPTR^.NAME = AVAL THEN GOTO 1
         ELSE CTPTR := CTPTR^.NXTEL;
   END;
1: DISX := I;
END → SEARCH ↓ ;

PROCEDURE INCONST (VAR V : INTEGER; P : CTP; CONST NXT : CTP) ;
   → INPUT PARAMETER : NXT. SEARCHING IS TO BEGIN AT NXT
      OUTPUT PARAMETER : V = VALUE
                         P = TYPE POINTER , P = NIL IF ERROR ↓
   VAR SIGN : BOOLEAN; PT : CTP;
BEGIN SIGN := FALSE; P := NIL;
   IF NO = 7 THEN
   BEGIN SIGN := CL = 2;
      IF CL ≤ 2 THEN
      BEGIN INSYMBOL; IF NO = 1 THEN ERROR(3)  END;
   END;
   IF NO = 2 THEN
   BEGIN CASE CL OF
1:       P := INTPTR;
2:       P := REALPTR;
3:       P := ALFAPTR;
4:       P := CHARPTR;
      END;
      IF SIGN THEN V := -IVAL ELSE V := +IVAL;
      INSYMBOL;
   END ELSE
   IF NO = 1 THEN
   BEGIN PT := CTPTR;
      SRCHREC(NXT);
      IF CTPTR = NIL THEN SEARCH;
      IF CTPTR = NIL THEN ERROR(12) ELSE
      WITH CTPTR^ DO
      BEGIN IF (KLASS ≠ KONST) ∨ (CONKIND = FORMAL) THEN ERROR(63)
         ELSE
         BEGIN P := CONTYPE;  V := VALUES END;
      END;
      CTPTR := PT;  INSYMBOL;
   END ELSE ERROR(3);
END → INCONST ↓ ;

→ ------------------------------------------------------------------ ↓

→ CODE GENERATING ROUTINES ↓

PROCEDURE NOOP;
BEGIN WHILE CP < 4 DO
   BEGIN APPEND(BUF,15,NOP);
      CP := CP + 1;
   END ;
END → NOOP ↓ ;

PROCEDURE GEN15(OP,I,J,K : SHRTINT);
BEGIN LASTOP := OP ; LASTI := I ;
   IF CP ≠ 4 THEN
   BEGIN CP := CP + 1; APPEND(BUF,6,OP)  END ELSE
   BEGIN CODE[CA] := BUF;  BUF := OP;  CP := 1;
      CA := CA + 1;  IC := IC + 1;
      IF CA > CODMAX THEN
      BEGIN ERROR(90); CA := 1;
      END;
   END;
   BUF := ((8*BUF + I)*8 + J)*8 + K ;
END → GEN15 ↓ ;

PROCEDURE GEN30(OP,I,J,K : SHRTINT);
BEGIN LASTOP := OP ; LASTI := I ;
   IF CP = 3 THEN →NOOP↓
   BEGIN APPEND(BUF,15,NOP); CP := 4 END;
   IF CP < 4 THEN
   BEGIN CP := CP + 2; APPEND(BUF,6,OP)  END ELSE
   BEGIN CODE[CA] := BUF; BUF := OP; CP := 2;
      CA := CA + 1;  IC := IC + 1;
      IF CA > CODMAX THEN
      BEGIN ERROR(90);  CA := 1;
      END;
   END;
   BUF := (8*BUF + I)*8 + J ;
   IF K ≥ 0 THEN APPEND(BUF,18,K) ELSE APPEND(BUF,18,777777B+K) ;
END → GEN30 ↓ ;

PROCEDURE BXIXJ(I, J : SHRTINT) ;
→TO AVOID B XI XJ INSTRUCTIONS WHENEVER POSSIBLE↓
BEGIN IF (J = LASTI) ∧ (LASTOP ≥ 10B) ∧ (LASTOP ≤ 45B)
   ∧ ¬(LASTOP IN [20B,21B,43B]) THEN
   BEGIN IF BUF ≥ 0 THEN BUF := BUF - LASTI*64 + I*64 ELSE
      BEGIN BUF := - BUF ;
         BUF := BUF - (7 - LASTI)*64 + (7 - I)*64 ;
         BUF := - BUF
      END ;
      LASTI := I
   END ELSE GEN15(10B,I,J,0)
END →BXIXJ↓ ;

PROCEDURE INS(FADR : ADDRESS ; FCP, FCA : SHRTINT) ;
BEGIN IF CA ≠ FCA THEN INSERT(FADR,(4-FCP)*15,CODE[FCA])
                   ELSE INSERT(FADR,(CP-FCP)*15,BUF)
END ;

→ ------------------------------------------------------------------ ↓

→ ROUTINES TO PRINT CODE AND JUMPTABLE AND TO OUTPUT CODE ↓

PROCEDURE PRTCOMP;
   → GLOBAL ARRAYS : JB1,JB2,JX1,JX2,REL,FS,R1,SH ↓
   VAR II,JJ,KK : CHAR;
      C,CC,S,IT3, OP,I,J,K : SHRTINT;
      M,IT4 : SHRTINT;

   PROCEDURE OUTCH(C : CHAR) ;
   BEGIN WRITE(C) END ;

   PROCEDURE SPACE ;
   BEGIN WRITE(≡ ≡ : 3) END ;

BEGIN
   IC := IC - CA - 1;
   M := -77B;  IT4 := -7B;
   FOR IT3 := 1 TO CA DO
   BEGIN BUF := -CODE[IT3];  OUTCH(EOL);
      OUTCH(≡ ≡) ; OUTCH(≡ ≡) ; WRITE(IC+IT3 : 6 OCT);  S := 0;
      REPEAT IT := BUF; APPEND(IT,S+6,M); OP := -IT;
         C := OP MOD 8;
         IT := BUF;  APPEND(IT,S+9,IT4); I := -IT;
         IT := BUF;  APPEND(IT,S+12,IT4); J := -IT;
         IT := BUF;
         IF (OP < 8) ∨ ((OP ≥ 40) ∧ (C ≤ 2)) THEN
         BEGIN S := S+30;  APPEND(IT,S,MASK) END ELSE
         BEGIN S := S+15;  APPEND(IT,S,IT4) END;
         K := -IT;

      CC := OP DIV 8;
      II :=CHR(I+INT(≡0≡)); JJ := CHR(J+INT(≡0≡)); KK :=CHR(K+INT(≡0≡));
      OUTCH(EOL); WRITE(BLANK);
      IF CC < 5 THEN
      CASE CC OF
0:       IF OP = 3 THEN
         BEGIN OUTCH(JX1[I]);  OUTCH(JX2[I]);  OUTCH(≡ ≡);
            SPACE;  OUTCH(≡X≡);  OUTCH(JJ);  OUTCH(≡,≡);
            WRITE(K : 6 OCT);
         END ELSE
         BEGIN OUTCH(JB1[OP]);  OUTCH(JB2[OP]);  OUTCH(≡ ≡);
            SPACE;
            IF OP > 3 THEN
            BEGIN OUTCH(≡B≡);  OUTCH(II);  OUTCH(REL[OP]);
               OUTCH(≡B≡);  OUTCH(JJ);  OUTCH(≡,≡);  WRITE(K : 6 OCT);
            END ELSE
            BEGIN IF OP = 2 THEN
               BEGIN OUTCH(≡B≡) ; OUTCH(II) ; OUTCH(≡+≡) END ;
               WRITE(K : 6 OCT)
            END;
         END → 0 ↓ ;
1:       BEGIN OUTCH(≡B≡);  OUTCH(≡X≡);  OUTCH(II);  SPACE;
            IF OP > 11 THEN
            BEGIN OUTCH(≡¬≡);  II := JJ; JJ := KK; KK := II  END;
            OUTCH(≡X≡);  OUTCH(JJ);
            C := OP MOD 4;
            IF C ≠ 0 THEN
            BEGIN OUTCH(REL[C]);  OUTCH(≡X≡);  OUTCH(KK)  END;
         END → 1 ↓ ;
2:       BEGIN OUTCH(SH[OP]);  OUTCH(≡X≡);  OUTCH(II);  SPACE;
            IF OP < 18 THEN
            BEGIN OUTCH(JJ);  OUTCH(KK)  END ELSE
            BEGIN OUTCH(≡B≡);  OUTCH(JJ);  OUTCH(≡,≡);
               OUTCH(≡X≡);  OUTCH(KK);
            END;
         END → 2 ↓ ;
3:       BEGIN OUTCH(SH[OP DIV 2]);  OUTCH(≡X≡);  OUTCH(II);
            SPACE;  OUTCH(≡X≡);  OUTCH(JJ);
            IF ODD(OP) THEN OUTCH(≡-≡) ELSE OUTCH(≡+≡);
            OUTCH(≡X≡);  OUTCH(KK);
         END → 3 ↓ ;
4:       BEGIN C := OP MOD 4;
            IF OP = 38 THEN
            BEGIN OUTCH(≡N≡);  OUTCH(≡O≡)  END ELSE
            IF C = 3 THEN
            BEGIN IF OP = 35 THEN OUTCH(≡M≡) ELSE OUTCH(≡C≡);
               OUTCH(≡X≡);  OUTCH(II);  SPACE;
               IF OP = 35 THEN OUTCH(JJ) ELSE OUTCH(≡X≡) ;
               OUTCH(KK);
            END ELSE
            BEGIN OUTCH(FS[C]);  OUTCH(≡X≡);  OUTCH(II);
               SPACE;  OUTCH(≡X≡);  OUTCH(JJ);
               IF OP < 36 THEN OUTCH(≡*≡) ELSE OUTCH(≡/≡);
               OUTCH(≡X≡);  OUTCH(KK);
            END;
         END → 4 ↓ ;
      END → CASE ↓ ELSE
      BEGIN
         OUTCH(≡S≡);  OUTCH(FS[CC]);  OUTCH(II);
         SPACE;  OUTCH(R1[C]);  OUTCH(JJ);
         IF C IN [5,7] THEN OUTCH(≡-≡) ELSE OUTCH(≡+≡) ;
         IF C ≤ 2 THEN WRITE(K : 6 OCT) ELSE
         BEGIN OUTCH(≡B≡);  OUTCH(KK)  END;
      END;

      UNTIL S ≥ 60;
   END;
   IC := IC + CA + 1;  OUTCH(EOL);
END → PRTCOMP ↓ ;

PROCEDURE PRJMPTAB ;
 → PRINTS OUT JMPTAB.
   LOADPOINT OF JMPTAB IN PARMLIST.LPJMPTAB ↓
   VAR I : SHRTINT;
BEGIN IF JMPIX > 0 THEN WRITE(EOL,≡1≡,EOL) ;
   FOR I := 0 TO JMPIX - 1 DO
   WRITE(≡ ≡ : 2,PARMLIST.LPJMPTAB+I:6 OCT,≡ ≡,JMPTAB[I]:20 OCT,EOL)
END →PRJMPTAB↓ ;

PROCEDURE WRITOUT ;
 →CALLED AT PROCEDURE END, UPDATING ITS CODE (INSERTING ADDRESSES
   OF CONSTANTS) AND WRITING OUT CODE TOGETHER WITH THE CONSTANTS
   USED IN THIS PROCEDURE↓
   VAR IT2 : SHRTINT;
BEGIN
   NOOP ; CODE[CA] := BUF ;
   FOR IT := 1 TO LCX DO
   WITH CSTTB[IT] DO
   BEGIN
      CA := CA + 1 ;
      IF CA > CODMAX THEN
      BEGIN ERROR(90) ; CA := 1 END ELSE
      BEGIN
         CODE[CA] := VALU ; IT1 := INX ;
         REPEAT
            WITH UNDLAB[IT1] DO
            BEGIN INS(IC,LFTSH,PLACE) ; IT2 := IT1 ; IT1 := SUCC END
         UNTIL IT1 = 0 ;
         UNDLAB[IT2].SUCC := CHNIX ;
         CHNIX := INX ; IC := IC + 1
      END
   END ;
   FOR IT := 1 TO CA DO
   BEGIN PASCLGO^ := CODE[IT] ; PUT(PASCLGO) END ;
   IF PRCODE THEN
   BEGIN
      IC := IC - LCX ; CA := CA - LCX ; PRTCOMP ;
      FOR IT := 1 TO LCX DO
      BEGIN
         CA := CA+1 ; WRITE(≡ ≡:2,IC:6 OCT,≡ ≡,CODE[CA]:20 OCT,EOL) ;
         IC := IC + 1
      END ;
      IF ¬ EOLFLAG THEN
      WRITE(≡ ≡:CHCNT+8) ;
   END
END → WRITOUT ↓ ;

→ ------------------------------------------------------------------ ↓

PROCEDURE MULOPT(VAL1:SHRTINT; VAR EXP1,EXP2:SHRTINT; OPT:OPTPWR);
   →MULOPT DECIDES IF VAL = 2**EXP1                    : OPT = PUREP
                           = 2**EXP1*(2**EXP2+1)        : OPT = POSP
                           = 2**EXP1*(2**EXP2-1)        : OPT = NEGP
                           OTHER                        : OPT = NOOPT ↓
   VAR E1,E2 : SHRTINT;
      VAL : SHRTINT;
BEGIN EXP1 := 0 ; EXP2 := 0 ;
   IF VAL1 > 0 THEN
   BEGIN E1 := 0;
      VAL := VAL1 ;
      WHILE ¬ ODD(VAL) DO
      BEGIN VAL := VAL DIV 2; E1 := E1 + 1 END;
      IF VAL = 1 THEN
      BEGIN OPT := PUREP; EXP1 := E1 END ELSE
      BEGIN VAL := VAL DIV 2; E2 := 1;
         IF ODD(VAL) THEN
         BEGIN
            REPEAT VAL := VAL DIV 2; E2 := E2 + 1;
            UNTIL ¬ ODD(VAL);
            IF VAL > 0 THEN OPT := NOOPT ELSE
            BEGIN OPT := NEGP;
               EXP2 := E2; EXP1 := E1;
            END;
         END ELSE
         BEGIN
            REPEAT VAL := VAL DIV 2; E2 := E2 + 1;
            UNTIL ODD(VAL);
            IF VAL > 1 THEN OPT := NOOPT  ELSE
            BEGIN OPT := POSP;
               EXP2 := E2; EXP1 := E1;
            END;
         END;
      END;
   END ELSE OPT := NOOPT;
END →MULOPT↓;

FUNCTION LOG2(VAL1:INTEGER) : SHRTINT;
   VAR E : SHRTINT; VAL : INTEGER;
BEGIN E := 1;
   VAL := VAL1;
   WHILE VAL > 0 DO
   BEGIN VAL := VAL DIV 2; E := E + 1  END;
   LOG2 := E;
END →LOG2↓;

PROCEDURE SKIP(FNO : SHRTINT) ;
BEGIN
   WHILE (ERRCL[NO] = IRRELSY) ∧ (FNO ≠ NO) DO
   IF (NO = 38) ∧ (CL = 2) THEN →RECORD↓
   BEGIN REPEAT INSYMBOL; SKIP(49);
      UNTIL ¬(NO IN [16,26]);
      IF NO = 22 THEN INSYMBOL ;
   END ELSE INSYMBOL;
END → SKIP ↓ ;

→ ------------------------------------------------------------------ ↓

PROCEDURE PACKANDNORM(FRP : RG3) ;
BEGIN GEN15(27B,FRP,0,FRP) ; GEN15(24B,FRP,0,FRP) END ;

PROCEDURE JUMPTO(FADR : ADDRESS) ;
BEGIN NOOP ; GEN30(71B,7,0,IC+1) ; GEN30(04B,0,0,FADR) END ;

PROCEDURE LDCST(FVAL : INTEGER) ;
 → ENTERS CONSTANT WITH VALUE FVAL INTO CONSTANTTABLE CSTTB IFF
    NOT YET PRESENT, ELSE CHAINS OCCURRENCES OF FVAL IN CODE
    (THROUGH UNDLAB)  ↓
   VAR IT : SHRTINT;
BEGIN
   RP := RP + 1 ; IF RP = 6 THEN ERROR(33) ;
   GEN30(51B,RP,0,0) ;
   FOR IT := 1 TO LCX DO
   WITH CSTTB[IT] DO
   IF VALU = FVAL THEN
   BEGIN
      IF CHNIX = 0 THEN ERROR(75) ELSE
      BEGIN
         WITH UNDLAB[CHNIX] DO
         BEGIN
            IT1 := SUCC ; SUCC := INX ;
            INX := CHNIX ; PLACE := CA ; LFTSH := CP
         END ;
         CHNIX := IT1
      END ;
      GOTO 10
   END ;
   IF LCX = CSTMAX THEN BEGIN ERROR(84) ; GOTO 10 END ;
   IF CHNIX = 0 THEN BEGIN ERROR(75) ; GOTO 10 END ;
   LCX := LCX + 1 ;
   WITH CSTTB[LCX] DO
   BEGIN VALU := FVAL ; INX := CHNIX END ;
   WITH UNDLAB[CHNIX] DO
   BEGIN IT1 := SUCC ; SUCC := 0 ; PLACE := CA ; LFTSH := CP END ;
   CHNIX := IT1 ;
10:END → LDCST ↓ ;

PROCEDURE MULTCODE(FRP : RG3) ;
→GENERATES CODE FOR REAL MULTIPLICATION, ASSUMING FIRST OPERAND
 IN X-RP, THE OTHER IN X-FRP; RESULT IN X-RP↓
BEGIN IF ROUNDING THEN GEN15(41B,RP,RP,FRP)
                  ELSE GEN15(40B,RP,RP,FRP)
END →MULTCODE↓ ;

PROCEDURE CHECKBNDS(FRP: RG3; FMIN,FMAX: INTEGER; FADR: ADDRESS) ;
→DONT USE WITH FRP IN [0,7]↓
BEGIN GEN30(71B,7,0,IC) ;
   IF FMIN ≠ 0 THEN
   BEGIN IF ABS(FMIN) ≥ TWOTO17 THEN LDCST(FMIN) ELSE
      BEGIN RP := RP + 1 ; GEN30(71B,RP,0,FMIN) END ;
      GEN15(37B,0,FRP,RP) ; RP := RP - 1 ;
   END ;
   IF ABS(FMAX) ≥ TWOTO17 THEN LDCST(FMAX) ELSE
   BEGIN RP := RP + 1 ; GEN30(71B,RP,0,FMAX) END ;
   GEN15(37B,RP,RP,FRP) ;
   IF FMIN ≠ 0 THEN GEN15(12B,0,RP,0) ELSE GEN15(12B,0,RP,FRP) ;
   GEN30(03B,3,0,FADR) ; RP := RP - 1 ;
END →CHECKBNDS↓ ;

PROCEDURE LOADBASE(FRP, FLEVEL : RG3) ;
   VAR I : SHRTINT ;
BEGIN GEN15(56B,FRP,5,0) ;
   FOR I := 1 TO LEVEL - FLEVEL - 1 DO GEN15(53B,FRP,FRP,0) ;
END →LOADBASE↓ ;

PROCEDURE TRANSFER(FATTR : ATTR ; FRP : SHRTINT) ;
→DEPENDING ON THE VALUE OF FRP, TRANSFER GENERATES CODE FOR EITHER
 LOADING THE EXPRESSION DESCRIBED BY FATTR INTO REGISTER X-FRP
 OR FOR STORING X-FRP AT LOCATION DESCRIBED BY FATTR (TAKING INTO
 ACCOUNT CDC 6000 HARDWARE FEATURES)↓
   VAR LRP, REG : SHRTINT; AT : ADDRESS;  BT : BOOLEAN;
BEGIN WITH FATTR DO
  IF TYPTR ≠ NIL THEN
    CASE KIND OF
    VARBL: BEGIN IF (FRP > 5) ∧ PCKD THEN
             BEGIN PCKD := FALSE ; TRANSFER(FATTR,1) ;
               IT := BITADR + BITSZ ; BT := IT ≠ WORDLENGTH ;
               IF BT THEN GEN15(20B,1,0,IT) ;
               GEN15(43B,0,0,WORDLENGTH-BITSZ) ; GEN15(11B,1,0,1) ;
               GEN15(15B,FRP,FRP,0) ; GEN15(12B,FRP,FRP,1) ;
               IF BT THEN GEN15(20B,FRP,0,WORDLENGTH-IT) ;
               GEN15(54B,FRP,1,0)
             END ELSE
             BEGIN LRP := FRP ;
               IF ACCESS = DRCT THEN
               BEGIN IF FRP < 5 THEN
                 BEGIN RP := RP + 1 ; LRP := RP END ELSE
                 IF FRP = 5 THEN ERROR(33) ;
                 IF BREG IN [0,LEVEL] THEN
                 BEGIN IF BREG ≠ 0 THEN REG := 5 ELSE REG := 0 ;
                   GEN30(51B,LRP,REG,DPLMT) ;
                 END ELSE
                 BEGIN LOADBASE(5,BREG) ; GEN30(52B,LRP,5,DPLMT) END ;
               END ELSE
               IF ACCESS = INXD THEN
               BEGIN IF BREG IN [0,LEVEL] THEN
                 BEGIN IF BREG ≠ 0 THEN REG := 5 ELSE REG := 0 ;
                   IF DPLMT = 0 THEN GEN15(53B,LRP,RP,REG) ELSE
                   BEGIN IF REG = 0 THEN GEN30(52B,LRP,RP,DPLMT) ELSE
                     BEGIN GEN30(62B,7,RP,DPLMT) ;
                       GEN15(56B,LRP,7,5)
                     END
                   END
                 END ELSE
                 BEGIN GEN30(62B,7,RP,DPLMT) ;
                   LOADBASE(5,BREG) ; GEN15(53B,LRP,5,7)
                 END
               END ELSE
               BEGIN IF DPLMT = 0 THEN GEN15(53B,LRP,RP,0)
                                  ELSE GEN30(52B,LRP,RP,DPLMT)
               END ;
               IF PCKD THEN
               BEGIN IF BITADR ≠ 0 THEN GEN15(20B,LRP,0,BITADR) ;
                 GEN15(21B,LRP,0,WORDLENGTH-BITSZ) ; PCKD := FALSE
               END
             END
           END ;
    SVAL : BEGIN IF FRP < 5 THEN
             BEGIN RP := RP + 1 ; LRP := RP END ELSE
             IF FRP > 5 THEN LRP := FRP ELSE ERROR(33) ;
             IF VAL = 0 THEN GEN15(13B,LRP,0,0)
                        ELSE GEN30(71B,LRP,0,VAL)
           END ;
    LVAL : BEGIN IF CTERM ≠ 0 THEN
             BEGIN GEN30(71B,0,0,CTERM) ; GEN15(36B,FRP,RP,0) END ELSE
             IF RP ≠ FRP THEN BXIXJ(FRP,RP)
           END ;
    LCOND: BEGIN IF ARITH THEN
             BEGIN IF JMP ≤ 1 THEN
               BEGIN GEN15(43B,FRP,0,0) ; AT := IC + 1 ;
                 GEN30(03B,JMP,0,AT) ; GEN30(71B,FRP,0,1) ; NOOP ;
               END ELSE
               BEGIN GEN15(43B,0,0,1) ;
                 IF JMP = 2 THEN GEN15(11B,FRP,0,RP)
                            ELSE GEN15(15B,FRP,0,RP) ;
                 GEN15(20B,FRP,0,1)
               END
             END ELSE
             BEGIN IF JMP ≠ 0 THEN
               BEGIN GEN15(43B,0,0,59) ; GEN15(17B,FRP,0,RP) END ELSE
               IF RP ≠ FRP THEN BXIXJ(FRP,RP)
             END
           END
    END →CASE KIND↓
END →TRANSFER↓ ;

PROCEDURE LOADADR(FATTR : ATTR ; FRP : SHRTINT) ;
→GENERATES CODE FOR LOADING THE ADDRESS OF THE VARIABLE DESCRIBED
 BY FATTR INTO X-FRP↓
  VAR REG : SHRTINT ;
BEGIN WITH FATTR DO
  IF TYPTR ≠ NIL THEN
  IF PCKD THEN ERROR(87) ELSE
  CASE ACCESS OF
  DRCT  : IF BREG IN [0,LEVEL] THEN
            BEGIN IF BREG ≠ 0 THEN REG := 5 ELSE REG := 0 ;
              GEN30(71B,FRP,REG,DPLMT)
            END ELSE
            BEGIN LOADBASE(5,BREG) ; GEN30(72B,FRP,5,DPLMT) END ;
  INDRCT: IF DPLMT ≠ 0 THEN GEN30(72B,FRP,RP,DPLMT) ELSE
            IF RP ≠ FRP THEN BXIXJ(FRP,RP) ;
  INXD  : IF BREG IN [0,LEVEL] THEN
            BEGIN IF BREG ≠ 0 THEN REG := 5 ELSE REG := 0 ;
              IF DPLMT = 0 THEN GEN15(73B,FRP,RP,REG) ELSE
              BEGIN IF REG = 0 THEN GEN30(72B,FRP,RP,DPLMT) ELSE
                BEGIN GEN30(62B,7,RP,DPLMT) ; GEN15(76B,FRP,7,5) END ;
              END
            END ELSE
            BEGIN GEN30(62B,7,RP,DPLMT) ;
              LOADBASE(5,BREG) ; GEN15(73B,FRP,5,7)
            END ;
  END
END →LOADADR↓ ;

PROCEDURE GENJP(FJPADDR : ADDRESS) ;
→ ACCORDING TO THE GLOBAL ATTRIBUTE RECORD GATTR (DEFINING AN
   EXPRESSION), THIS PROCEDURE PERFORMS CODE GENERATION FOR A
   CONDITIONAL JUMP (ADDRESS = FJPADDR), DEPENDING ON THE TRUTH
   VALUE OF THE (NECESSARILY) BOOLEAN EXPRESSION ↓
  BEGIN
     WITH GATTR DO
     IF TYPTR ≠ BOOLPTR THEN ERROR(57) ELSE
     BEGIN
        IF KIND ≤ SVAL THEN TRANSFER(GATTR,RP) ;
        IF KIND = LCOND THEN
           IF (JMP ≤ 1) ∧ ARITH THEN GEN30(03B,JMP,0,FJPADDR) ELSE
           GEN30(03B,JMP,1,FJPADDR)
        ELSE GEN30(03B,0,RP,FJPADDR)
     END
  END → GENJP ↓ ;

PROCEDURE ADDRESSVAR(FCTP : CTP ; VAR FATTR : ATTR) ;
→GENERATES CODE TO ADDRESS THE QUANTITY WITH CTPTR = FCTP AND
 BUILDS UP ITS ATTRIBUTES IN FATTR↓
BEGIN WITH FCTP^, FATTR DO
  BEGIN KIND := VARBL ;
    IF KLASS = VARS THEN
    BEGIN TYPTR := VTYPE ; PCKD := FALSE ;
      IF VKIND = ACTUAL THEN
      BEGIN ACCESS := DRCT ; DPLMT := VADDR ; BREG := VLEVEL ;
      END ELSE
      BEGIN RP := RP + 1 ; IF RP = 6 THEN ERROR(33) ;
        IF VLEVEL = LEVEL THEN GEN30(51B,RP,5,VADDR) ELSE
        BEGIN LOADBASE(RP,VLEVEL) ; GEN30(52B,RP,RP,VADDR) END ;
        ACCESS := INDRCT ; DPLMT := 0 ;
      END ;
    END ELSE
    IF KLASS = FIELD THEN
    BEGIN TYPTR := FLDTYPE ;
      WITH DISPLAY[DISX] DO
      BEGIN IF OCCUR = CWITH THEN
        BEGIN ACCESS := DRCT ; BREG := CLEV ; DPLMT := FLDADDR + CDSPL
        END ELSE
        BEGIN RP := RP + 1 ; IF RP = 6 THEN ERROR(33) ;
          GEN30(51B,RP,5,VDSPL) ;
          ACCESS := INDRCT ; DPLMT := FLDADDR ;
        END ;
        IF BITWIDTH ≠ 0 THEN
        BEGIN PCKD := TRUE ; BITADR := BITDISPL ; BITSZ := BITWIDTH
        END ELSE PCKD := FALSE
      END
    END ELSE
    BEGIN TYPTR := PROCTYPE ; ACCESS := DRCT ; BREG := PROCLEVEL + 1 ;
      DPLMT := 2 ; PCKD := FALSE ;
      IF PROCKIND = FORMAL THEN ERROR(81) ELSE
      IF LEVEL ≠ BREG THEN ERROR(85)
    END
  END →WITH FCTP^, FATTR↓ ;
END →ADDRESSVAR↓ ;

→ ------------------------------------------------------------ ↓

PROCEDURE STATEMENT  ; FORWARD ;

PROCEDURE EXPRESSION ; FORWARD ;

PROCEDURE PASSPARAMS ; FORWARD ;

PROCEDURE VARIABLE ;
  VAR LATTR : ATTR ;
BEGIN ADDRESSVAR(CTPTR,LATTR) ;
  INSYMBOL ;
  WHILE NO IN [11,17,18] DO →[,.,^↓
  IF NO = 11 THEN →[↓
  BEGIN
    REPEAT WITH LATTR DO
      IF TYPTR ≠ NIL THEN
      IF TYPTR^.FORM ≠ ARRAYS THEN
      BEGIN ERROR(34) ; TYPTR := NIL END ;
      INSYMBOL ; EXPRESSION ;
      IF GATTR.TYPTR ≠ NIL THEN
      BEGIN IF GATTR.TYPTR^.FORM > SYMBOLIC THEN ERROR(35) ;
        IF LATTR.TYPTR ≠ NIL THEN
        BEGIN PT := LATTR.TYPTR^.INXTYPE ;
          IF ((GATTR.TYPTR^.FORM = SYMBOLIC) ∨ (PT^.FORM = SYMBOLIC)) ∧
          (GATTR.TYPTR ≠ PT) THEN ERROR(36) ;
          WITH GATTR DO
          IF KIND = SVAL THEN
          BEGIN IF (LATTR.TYPTR^.LO > VAL) ∨ (LATTR.TYPTR^.HI < VAL)
            THEN ERROR(99) ;
            IT := VAL
          END ELSE
          IF KIND = LVAL THEN IT := CTERM ELSE
          BEGIN TRANSFER(GATTR,RP) ; IT := 0 END ;
          WITH LATTR, TYPTR^ DO
          BEGIN DPLMT := DPLMT + (IT - LO)*AELTYPE^.SIZE ;
            IF GATTR.KIND ≠ SVAL THEN
            BEGIN IF INXCHECK THEN CHECKBNDS(RP,LO-IT,HI-IT,INXERR) ;
              IF OPTTYP = NOOPT THEN
              BEGIN GEN30(71B,6,0,AELTYPE^.SIZE) ;
                GEN15(42B,RP,RP,6)
              END ELSE
              BEGIN IF EXP1 ≠ 0 THEN GEN15(20B,RP,0,EXP1) ;
                IF OPTTYP ≠ PUREP THEN
                BEGIN GEN15(10B,0,RP,0) ; GEN15(20B,RP,0,EXP2) ;
                  IF OPTTYP = POSP THEN GEN15(36B,RP,RP,0)
                                   ELSE GEN15(37B,RP,RP,0)
                END
              END ;
              IF ACCESS = DRCT THEN ACCESS := INXD ELSE
              BEGIN RP := RP - 1 ; GEN15(36B,RP,RP,RP+1) END
            END
          END ;
        END →IF LATTR.TYPTR <> NIL↓
      END →IF GATTR.TYPTR <> NIL↓ ;
      IF LATTR.TYPTR ≠ NIL THEN LATTR.TYPTR := LATTR.TYPTR^.AELTYPE ;
    UNTIL NO ≠ 15 →,↓ ;
    IF NO ≠ 12 THEN →]↓ ERROR(37) ELSE INSYMBOL
  END →IF NO = 11↓ ELSE
  IF NO = 17 THEN →.↓
  BEGIN INSYMBOL ;
    IF NO = 1 THEN →ID↓
    BEGIN IF LATTR.TYPTR ≠ NIL THEN
      BEGIN IF LATTR.TYPTR^.FORM = RECORDS THEN
        WITH LATTR DO
        BEGIN SRCHREC(TYPTR^.FSTFLD) ;
          IF CTPTR = NIL THEN
          BEGIN ERROR(39) ; CTPTR := UNDECPTR END ;
          WITH CTPTR^ DO
          BEGIN TYPTR := FLDTYPE ; DPLMT := DPLMT + FLDADDR ;
            IF BITWIDTH ≠ 0 THEN
            BEGIN BITADR := BITDISPL ; BITSZ := BITWIDTH ;
              PCKD := TRUE
            END ELSE PCKD := FALSE
          END
        END ELSE
        BEGIN ERROR(38) ; LATTR.TYPTR := NIL END ;
      END ;
      INSYMBOL
    END ELSE
    BEGIN ERROR(41) ; LATTR.TYPTR := NIL END
  END →IF NO = 17↓ ELSE →^↓
  BEGIN WITH LATTR DO
    IF TYPTR ≠ NIL THEN
    BEGIN TRANSFER(LATTR,RP) ; ACCESS := INDRCT ; DPLMT := 0 ;
      IF TYPTR^.FORM = FILES THEN TYPTR := TYPTR^.FELTYPE ELSE
      IF TYPTR^.FORM = POINTER THEN TYPTR := TYPTR^.ELTYPE ELSE
      BEGIN ERROR(40) ; TYPTR := NIL END
    END ;
    INSYMBOL
  END →^↓ ;
  GATTR := LATTR
END →VARIABLE↓ ;

PROCEDURE FACTOR ;
  VAR LATTR : ATTR ; LPTR : CTP ; LRP, LB6 : SHRTINT ;
      AT : ADDRESS;  LPSVAL, IT2 : INTEGER;

  PROCEDURE ELEMENT ;
  →WORKS UP THE NEXT ELEMENT IN THE SET BEEING ANALYSED↓
  BEGIN
    EXPRESSION ;
    IF GATTR.TYPTR ≠ NIL THEN
    IF GATTR.TYPTR^.FORM > SYMBOLIC THEN ERROR(35) ELSE
    IF (GATTR.TYPTR = REALPTR) ∨ (GATTR.TYPTR = ALFAPTR) THEN
    ERROR(62) ELSE
    BEGIN IF LATTR.TYPTR ≠ NIL THEN
      IF ((LATTR.TYPTR^.FORM ≠ NUMERIC) ∨ (GATTR.TYPTR^.FORM ≠
      NUMERIC)) ∧ (LATTR.TYPTR ≠ GATTR.TYPTR) THEN ERROR(73) ;
      LATTR.TYPTR := GATTR.TYPTR ;
      IF GATTR.KIND = SVAL THEN INSERT(1,GATTR.VAL,LPSVAL) ELSE
      BEGIN TRANSFER(GATTR,RP) ; GEN15(63B,7,RP,0) ;
        IF LATTR.KIND = SVAL THEN
        BEGIN GEN30(71B,RP,0,1) ; GEN15(22B,RP,7,RP) ;
          LATTR.KIND := LVAL ; LATTR.CTERM := 0
        END ELSE
        BEGIN GEN30(71B,0,0,1) ; GEN15(22B,0,7,0) ;
          RP := RP - 1 ; GEN15(12B,RP,RP,0) ;
        END
      END
    END ;
  END →ELEMENT↓ ;

BEGIN IF NO = 1 THEN                                  →IDENTIFIER↓
  BEGIN SEARCH ;
    IF CTPTR = NIL THEN
    BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
    CASE CTPTR^.KLASS OF
TYPES: BEGIN ERROR(45) ; GATTR.TYPTR := NIL ; INSYMBOL END ;
KONST: WITH GATTR, CTPTR^ DO
         BEGIN TYPTR := CONTYPE ;
           IF CONKIND = ACTUAL THEN
           BEGIN IF ABS(VALUES) ≥ TWOTO17 THEN
             BEGIN LDCST(VALUES) ; KIND := LVAL ; CTERM := 0 END ELSE
             BEGIN KIND := SVAL ; VAL := VALUES END
           END ELSE →FORMAL↓
           BEGIN KIND := VARBL ; ACCESS := DRCT ;
             BREG := CLEVEL ; DPLMT := CADDR ; PCKD := FALSE ;
           END ;
           INSYMBOL
         END ;
PROC : BEGIN INSYMBOL ;
         IF (CTPTR^.PROCTYPE = NIL) ∨ (CTPTR^.PROCTYPE = CTPTR) THEN
         BEGIN ERROR(46) ; GATTR.TYPTR := NIL END ELSE
         IF NO ≠ 9 THEN →(↓
         BEGIN ERROR(79) ; GATTR.TYPTR := NIL END ELSE
         IF CTPTR ≤ PREDEFP THEN                           →**INLINE FCT**↓
         BEGIN LPTR := CTPTR ; INSYMBOL ; EXPRESSION ;
           IF GATTR.TYPTR ≠ NIL THEN
           CASE LPTR^.SEGSIZE OF
 →ODD↓ 1: BEGIN IF GATTR.TYPTR^.FORM ≠ NUMERIC THEN ERROR(47) ;
              TRANSFER(GATTR,RP) ;
              IF GATTR.TYPTR^.MIN ≥ 0 THEN GEN15(20B,RP,0,59) ELSE
              BEGIN GEN15(10B,0,RP,0) ; GEN15(20B,0,0,59) ;
                GEN15(13B,RP,RP,0) ;
              END ;
              WITH GATTR DO
              BEGIN TYPTR := BOOLPTR ; KIND := LCOND ; JMP := 2 ;
                ARITH := TRUE
              END
            END ;
 →INT↓ 2: BEGIN IF GATTR.TYPTR^.FORM > POWER THEN ERROR(44) ;
              GATTR.TYPTR := INTPTR
            END ;
 →CHR↓ 3: BEGIN IF GATTR.TYPTR^.FORM ≠ NUMERIC THEN ERROR(47) ;
              IF ASSCHECK THEN
              BEGIN TRANSFER(GATTR,RP) ;
                WITH GATTR DO
                BEGIN KIND := LVAL ; CTERM := 0 END ;
                CHECKBNDS(RP,0,63,ASSERR)
              END ;
              GATTR.TYPTR := CHARPTR
            END ;
 →EOF↓ 4: BEGIN IF GATTR.TYPTR^.FORM ≠ FILES THEN ERROR(44) ;
              WITH GATTR DO
              BEGIN DPLMT := DPLMT + 1 ; TRANSFER(GATTR,RP) ;
                TYPTR := BOOLPTR ; KIND := LCOND ; JMP := 2 ;
                ARITH := TRUE
              END
            END ;
 →ABS↓ 5: BEGIN IF (GATTR.TYPTR ≠ REALPTR) ∧ (GATTR.TYPTR^.FORM ≠
              NUMERIC) THEN ERROR(44) ;
              TRANSFER(GATTR,RP) ; GEN15(10B,0,RP,0) ;
              GEN15(21B,0,0,73B) ; GEN15(13B,RP,0,RP) ;
              WITH GATTR DO
              BEGIN IF TYPTR ≠ REALPTR THEN TYPTR := INTPTR ;
                KIND := LVAL ; CTERM := 0
              END
            END ;
 →SQR↓ 6: BEGIN IF (GATTR.TYPTR ≠ REALPTR) ∧ (GATTR.TYPTR^.FORM ≠
              NUMERIC) THEN ERROR(44) ;
              TRANSFER(GATTR,RP) ;
              WITH GATTR DO
              BEGIN IF TYPTR = REALPTR THEN MULTCODE(RP) ELSE
                BEGIN GEN15(42B,RP,RP,RP) ; TYPTR := INTPTR END ;
                KIND := LVAL ; CTERM := 0 ;
              END
            END ;
 →TRC↓ 7: BEGIN IF GATTR.TYPTR ≠ REALPTR THEN ERROR(44) ;
              TRANSFER(GATTR,RP) ;
              GEN15(26B,RP,7,RP) ; GEN15(22B,RP,7,RP) ;
              GEN15(13B,0,0,0) ; GEN15(36B,RP,RP,0) ;
              WITH GATTR DO
              BEGIN TYPTR := INTPTR ; KIND := LVAL ; CTERM := 0 END
            END ;
 →PRE↓ 8,
 →SUC↓ 9: IF (GATTR.TYPTR^.FORM > SYMBOLIC) ∨ (GATTR.TYPTR =
            REALPTR) ∨ (GATTR.TYPTR = ALFAPTR) THEN
            BEGIN ERROR(44) ; GATTR.TYPTR := NIL END ELSE
            BEGIN TRANSFER(GATTR,RP) ;
              WITH GATTR.TYPTR^ DO
              IF FORM = NUMERIC THEN
              BEGIN IT1 := MIN ; IT2 := MAX END ELSE
              BEGIN IT1 := 0 ; IT2 := FCONST^.VALUES END ;
              IT := LPTR^.SEGSIZE ;
              IF (ABS(IT1) ≥ TWOTO17) ∨ (ABS(IT2) ≥ TWOTO17) THEN
              BEGIN GEN30(71B,0,0,1) ;
                GEN15(47B-IT,RP,RP,0) ;   →36B OR 37B↓
              END ELSE GEN30(72B,RP,RP,2*IT-17) ;  →+1 OR -1↓
              IF ASSCHECK ∧ (GATTR.TYPTR ≠ INTPTR) THEN
              CHECKBNDS(RP,IT1,IT2,ASSERR) ;
              WITH GATTR DO
              BEGIN KIND := LVAL ; CTERM := 0 END
            END
          END →CASE LPTR^.SEGSIZE OF↓ ;
          IF NO ≠ 10 THEN →)↓
          BEGIN ERROR(48) ; GATTR.TYPTR := NIL END ELSE INSYMBOL
        END →IF CTPTR <= PREDEFP↓ ELSE                  →**EXTERNAL FCT**↓
        BEGIN FOR IT := 1 TO RP DO                        →**USERDEF. FCT**↓
          BEGIN BXIXJ(6,IT) ; GEN30(51B,6,5,LC+TCT) ;
            TCT := TCT + 1 ; IF TCT > TMAX THEN TMAX := TCT ;
          END ;
          IF CTPTR ≤ EXTPTR THEN  → SET BIT TO INFORM MONITOR ↓
          WITH PARMLIST DO EXTFLAGS := EXTFLAGS+[CTPTR^.SEGSIZE] ;
          LRP := RP ; LB6 := B6DPL ; LPTR := CTPTR^.PROCTYPE ;
          IF LB6 ≠ 3 THEN GEN30(61B,6,6,LB6) ; RP := 0 ;
          PASSPARAMS ;
          IF LB6 ≠ 3 THEN GEN30(61B,6,6,-LB6) ;
          B6DPL := LB6 ;
          FOR IT := LRP DOWNTO 1 DO
          BEGIN TCT := TCT - 1 ; GEN30(51B,IT,5,LC+TCT) END ;
          IF LRP = 5 THEN ERROR(33) ELSE
          BEGIN RP := LRP + 1 ;
            IF LB6 = 3 THEN IT := 2 ELSE IT := LB6 + 2 ;
            GEN30(51B,RP,6,IT) ;
          END ;
          WITH GATTR DO
          BEGIN TYPTR := LPTR ; KIND := LVAL ; CTERM := 0 END
        END
      END ;
VARS ,
FIELD : VARIABLE ;
    END →CASE CTPTR^.KLASS OF↓ ;
  END →IF NO = 1↓ ELSE
  IF NO = 2 THEN                                                →CONSTANT↓
  BEGIN WITH GATTR DO
    BEGIN IF ABS(IVAL) ≥ TWOTO17 THEN
      BEGIN LDCST(IVAL) ; KIND := LVAL ; CTERM := 0 END ELSE
      BEGIN KIND := SVAL ; VAL := IVAL END ;
      CASE CL OF
     1: TYPTR := INTPTR  ;
     2: TYPTR := REALPTR ;
     3: TYPTR := ALFAPTR ;
     4: TYPTR := CHARPTR ;
      END ;
    END ;
    INSYMBOL ;
  END →IF NO = 2↓ ELSE
  IF NO = 36 THEN                                                  →NIL↓
  BEGIN WITH GATTR DO
    BEGIN TYPTR := NILPTR ; KIND := SVAL ; VAL := NILVAL END ;
    INSYMBOL
  END ELSE
  IF NO = 5 THEN                                                   →NOT↓
  BEGIN INSYMBOL ; FACTOR ;
    WITH GATTR DO
    IF TYPTR ≠ NIL THEN
    IF TYPTR = BOOLPTR THEN
    BEGIN IF KIND = LCOND THEN
      BEGIN IF JMP ≤ 1 THEN JMP := 1 - JMP ELSE JMP := 5 - JMP ;
      END ELSE
      BEGIN TRANSFER(GATTR,RP) ; GEN15(43B,0,0,59) ;
        GEN15(17B,RP,0,RP) ; KIND := LVAL ; CTERM := 0
      END
    END ELSE ERROR(50)
  END →IF NO = 5↓ ELSE
  IF NO = 9 THEN                                                   →(↓
  BEGIN INSYMBOL ; EXPRESSION ;
    IF NO ≠ 10 THEN →)↓
    BEGIN ERROR(48) ; GATTR.TYPTR := NIL END ELSE INSYMBOL
  END ELSE
  IF NO = 11 THEN                                                  →[↓
  BEGIN INSYMBOL ;
    IF NO = 12 THEN →]↓
    WITH GATTR DO
    BEGIN TYPTR := LAMPTR ; KIND := SVAL ;
      VAL := 0 ; INSYMBOL
    END ELSE
    BEGIN WITH LATTR DO
      BEGIN TYPTR := NIL ; KIND := SVAL END ; LPSVAL := 0 ;
      ELEMENT ;
      WHILE NO = 15 DO →,↓
      BEGIN INSYMBOL ; ELEMENT END ;
      IF LPSVAL ≠ 0 THEN
      IF LPSVAL ≥ TWOTO17 THEN
      BEGIN LDCST(LPSVAL) ;
        IF LATTR.KIND = LVAL THEN
        BEGIN RP := RP - 1 ; GEN15(12B,RP,RP,RP+1) END ELSE
        LATTR.KIND := LVAL ; LATTR.CTERM := 0
      END ELSE
      IF LATTR.KIND = SVAL THEN LATTR.VAL := LPSVAL ELSE
      BEGIN GEN30(71B,0,0,LPSVAL) ; GEN15(12B,RP,RP,0) END ;
      IF LATTR.TYPTR ≠ NIL THEN
      IF LATTR.TYPTR^.FORM = NUMERIC THEN LATTR.TYPTR := PNUMPTR
      ELSE LATTR.TYPTR := LATTR.TYPTR^.PWSET ;
      IF NO ≠ 12 THEN →]↓
      BEGIN ERROR(37) ; LATTR.TYPTR := NIL END ELSE INSYMBOL ;
      GATTR := LATTR
    END ;
  END →IF NO = 11↓ ELSE
  BEGIN ERROR(42) ; GATTR.TYPTR := NIL END
END →FACTOR↓ ;

PROCEDURE TERM ;
VAR LATTR : ATTR ; AT : ADDRESS ; BT1,BT2,BT3,BT4 : BOOLEAN ;
    LEXP1, LEXP2, LMOPCL : SHRTINT ; LOPT : OPTPWR ;
PROCEDURE CHECKDIV(FRP : RG3) ;
→DONOT USE WITH FRP = 7↓
BEGIN IF GATTR.KIND = SVAL THEN
  BEGIN IF GATTR.VAL = 0 THEN ERROR(102) ;
  END ELSE
  IF DIVCHECK THEN
  BEGIN GEN30(71B,7,0,IC) ; GEN30(03B,0,FRP,DIVERR) END ;
END →DIVCHECK↓ ;
BEGIN FACTOR ;
  IF NO = 6 THEN →MULOP↓
  BEGIN LOPT := NOOPT;
    IF (GATTR.KIND = SVAL) ∧ (CL = 1) THEN
    MULOPT(GATTR.VAL,LEXP1,LEXP2,LOPT) ;
    IF LOPT = NOOPT THEN
    BEGIN TRANSFER(GATTR,RP) ;
      WITH LATTR DO
      BEGIN TYPTR := GATTR.TYPTR ; KIND := LVAL ; CTERM := 0 END ;
    END ELSE LATTR := GATTR ;
    REPEAT LMOPCL := CL ; INSYMBOL ; FACTOR ;
      IF (LATTR.TYPTR ≠ NIL) ∧ (GATTR.TYPTR ≠ NIL) THEN
      BEGIN CASE LMOPCL OF
→ * ↓ 1: BEGIN BT1 := LATTR.TYPTR^.FORM = NUMERIC ;
           BT2 := GATTR.TYPTR^.FORM = NUMERIC ;
           BT3 := LATTR.TYPTR = REALPTR ;
           BT4 := GATTR.TYPTR = REALPTR ;
           IF LOPT ≠ NOOPT THEN
           BEGIN TRANSFER(GATTR,RP) ;
             IF BT4 THEN
             BEGIN TRANSFER(LATTR,RP) ; PACKANDNORM(RP) ;
               LATTR.TYPTR := REALPTR ;
               LOPT := NOOPT ; BT3 := TRUE ;
             END ;
             WITH LATTR DO
             BEGIN KIND := LVAL ; CTERM := 0 END ;
           END ELSE
           BEGIN IF (GATTR.KIND = SVAL) ∧ ¬ BT3 THEN
             MULOPT(GATTR.VAL,LEXP1,LEXP2,LOPT) ;
             IF LOPT = NOOPT THEN TRANSFER(GATTR,RP) ;
           END ;
           IF LOPT = NOOPT THEN BEGIN RP1 := RP ; RP := RP - 1 END ;
           IF BT3 ∧ BT4 THEN MULTCODE(RP1) ELSE
           IF BT1 ∧ BT2 THEN
           BEGIN IF LOPT = NOOPT THEN
             BEGIN GEN15(42B,RP,RP,RP1) ; GEN15(13B,0,0,0) ;
               GEN15(36B,RP,RP,0)
             END ELSE
             BEGIN IF LEXP1 ≠ 0 THEN GEN15(20B,RP,0,LEXP1) ;
               IF LOPT ≠ PUREP THEN
               BEGIN GEN15(10B,0,RP,0) ; GEN15(20B,RP,0,LEXP2) ;
                 IF LOPT = POSP THEN GEN15(36B,RP,RP,0)
                                ELSE GEN15(37B,RP,RP,0) ;
               END
             END ;
             LATTR.TYPTR := INTPTR ;
           END ELSE
           IF (BT1 ∧ BT4) ∨ (BT2 ∧ BT3) THEN
           BEGIN IF BT1 THEN PACKANDNORM(RP) ELSE PACKANDNORM(RP1) ;
             MULTCODE(RP1) ; LATTR.TYPTR := REALPTR
           END ELSE ERROR(50)
         END ;
→ / ↓ 2: BEGIN TRANSFER(GATTR,RP) ;
           IF GATTR.TYPTR^.FORM = NUMERIC THEN
           BEGIN PACKANDNORM(RP) ; GATTR.TYPTR := REALPTR END ;
           RP := RP - 1 ;
           IF LATTR.TYPTR^.FORM = NUMERIC THEN
           BEGIN PACKANDNORM(RP) ; LATTR.TYPTR := REALPTR END ;
           IF (GATTR.TYPTR = REALPTR) ∧ (LATTR.TYPTR = REALPTR) THEN
           BEGIN CHECKDIV(RP+1) ;
             IF ROUNDING THEN GEN15(45B,RP,RP,RP+1)
                         ELSE GEN15(44B,RP,RP,RP+1)
           END ELSE ERROR(50) ;
         END ;
→ AND ↓ 3: BEGIN TRANSFER(GATTR,RP) ; RP := RP - 1 ;
           IF (LATTR.TYPTR = GATTR.TYPTR) ∧ ((LATTR.TYPTR^.FORM =
           POWER) ∨ (LATTR.TYPTR = BOOLPTR)) THEN GEN15(11B,RP,RP,RP+1)
           ELSE ERROR(50)
         END ;
 →DIV↓ 4: BEGIN IF GATTR.KIND = SVAL THEN
              MULOPT(GATTR.VAL,LEXP1,LEXP2,LOPT) ;
           IF (LATTR.TYPTR^.FORM = NUMERIC) ∧ (GATTR.TYPTR^.FORM =
           NUMERIC) THEN
           BEGIN IF LOPT = PUREP THEN
             BEGIN IF LEXP1 ≠ 0 THEN GEN15(21B,RP,0,LEXP1) ;
               IF LATTR.TYPTR^.MIN < 0 THEN
               BEGIN GEN15(13B,0,0,0) ; GEN15(36B,RP,RP,0) END
             END ELSE
             BEGIN TRANSFER(GATTR,RP) ; CHECKDIV(RP) ;
               PACKANDNORM(RP) ; RP := RP - 1 ;
               GEN15(27B,RP,0,RP) ;
               GEN15(44B,RP,RP,RP+1) ; GEN15(26B,RP,7,RP) ;
               GEN15(22B,RP,7,RP) ; GEN15(13B,0,0,0) ;
              GEN15(36B,RP,RP,0) ;
             END ;
             LATTR.TYPTR := INTPTR
           END ELSE ERROR(50)
         END ;
 →MOD↓ 5: BEGIN IF GATTR.KIND = SVAL THEN
              MULOPT(GATTR.VAL,LEXP1,LEXP2,LOPT) ;
           IF (LATTR.TYPTR^.FORM = NUMERIC) ∧ (GATTR.TYPTR^.FORM =
           NUMERIC) THEN
           BEGIN IF LOPT = PUREP THEN
             BEGIN GEN15(10B,0,RP,0) ; GEN15(21B,0,0,LEXP1) ;
               GEN15(20B,0,0,LEXP1) ; GEN15(37B,RP,RP,0) ;
             END ELSE
             BEGIN TRANSFER(GATTR,RP) ;
               CHECKDIV(RP) ; GEN15(27B,6,0,RP) ; GEN15(24B,6,0,6) ;
               RP1 := RP ; RP := RP - 1 ;
               GEN15(27B,0,0,RP) ; GEN15(44B,6,0,6) ;
               GEN15(26B,6,7,6) ; GEN15(22B,6,7,6) ;
               GEN15(42B,6,RP1,6) ; GEN15(37B,RP,RP,6) ;
             END ;
             LATTR.TYPTR := INTPTR
           END ELSE ERROR(50)
         END ;
         END →CASE LMOPCL OF↓
      END ;
      LOPT := NOOPT
    UNTIL NO ≠ 6 ; →MULOP↓
    GATTR := LATTR
  END →IF NO = 6↓
END →TERM↓ ;

PROCEDURE SIMPLEEXP ;
VAR LATTR : ATTR ; LADOPCL : SHRTINT ; LFG,BT1,BT2 : BOOLEAN ;
BEGIN LFG := FALSE ;
  IF NO = 7 THEN →ADDOP↓
  BEGIN IF CL = 2 THEN LFG := TRUE ELSE IF CL = 3 THEN ERROR(51) ;
    INSYMBOL ;
  END ;
  TERM ;
  IF LFG ∨ (NO = 7) THEN
  BEGIN WITH LATTR DO
    BEGIN TYPTR := GATTR.TYPTR ; KIND := LVAL ; CTERM := 0 ;
      IF TYPTR ≠ NIL THEN
      BEGIN TRANSFER(GATTR,RP) ;
        IF LFG THEN
        BEGIN GEN15(13B,0,0,0) ;
          IF (TYPTR^.FORM = NUMERIC) ∨ (TYPTR = REALPTR) THEN
          GEN15(37B,RP,0,RP) ELSE ERROR(50)
        END
      END
    END ;
    WHILE NO = 7 DO
    BEGIN LADOPCL := CL ; INSYMBOL ; TERM ;
      IF (LATTR.TYPTR ≠ NIL) ∧ (GATTR.TYPTR ≠ NIL) THEN
      BEGIN BT1 := LATTR.TYPTR^.FORM = NUMERIC ;
        BT2 := GATTR.TYPTR^.FORM = NUMERIC ;
        IF BT1 ∧ BT2 ∧ (GATTR.KIND = SVAL) THEN
        BEGIN WITH LATTR DO
          BEGIN TYPTR := INTPTR ;
            CASE LADOPCL OF
            1: CTERM := CTERM + GATTR.VAL ;
            2: CTERM := CTERM - GATTR.VAL ;
            3: ERROR(50)
            END
          END
        END ELSE
        BEGIN TRANSFER(GATTR,RP) ; RP1 := RP ; RP := RP - 1 ;
          IF BT1 ∧ BT2 THEN
          BEGIN LATTR.TYPTR := INTPTR ;
            CASE LADOPCL OF
            1: GEN15(36B,RP,RP,RP1) ;
            2: GEN15(37B,RP,RP,RP1) ;
            3: ERROR(50)
            END
          END ELSE
          BEGIN IF BT1 THEN
            BEGIN PACKANDNORM(RP) ; LATTR.TYPTR := REALPTR
            END ELSE
            IF BT2 THEN
            BEGIN PACKANDNORM(RP1) ; GATTR.TYPTR := REALPTR
            END ;
            IF (LATTR.TYPTR = REALPTR) ∧ (GATTR.TYPTR = REALPTR) THEN
            BEGIN IF LADOPCL ≤ 2 THEN
              BEGIN IF ROUNDING THEN GEN15(33B+LADOPCL,RP,RP,RP1)
                               ELSE GEN15(27B+LADOPCL,RP,RP,RP1) ;
                GEN15(24B,RP,0,RP)
              END ELSE ERROR(50)
            END ELSE
            IF LATTR.TYPTR = GATTR.TYPTR THEN
            BEGIN IF (LATTR.TYPTR = BOOLPTR) ∧ (LADOPCL = 3) THEN
              GEN15(12B,RP,RP,RP1) ELSE
              IF LATTR.TYPTR^.FORM = POWER THEN
              CASE LADOPCL OF
              1: GEN15(13B,RP,RP,RP1) ; →NON-STANDARD PASCAL↓
              2: GEN15(15B,RP,RP,RP1) ;
              3: GEN15(12B,RP,RP,RP1) ;
              END ELSE ERROR(50)
            END ELSE ERROR(50)
          END
        END
      END
    END →WHILE NO = 7↓ ;
    GATTR := LATTR
  END →IF LFG OR (NO = 7)↓
END →SIMPLEEXP↓ ;

PROCEDURE EXPRESSION ;
VAR LATTR : ATTR ; LRELOPCL, LCST : SHRTINT ;
  LOF,BT1,BT2 : BOOLEAN ; AT : ADDRESS ;
BEGIN SIMPLEEXP ;
  IF NO = 8 THEN →RELOP↓
  BEGIN LOF := TRUE ;
    WITH GATTR DO
    IF (KIND = SVAL) ∧ ((CL = 7) ∨ (VAL = 0) ∧ (TYPTR ≠ BOOLPTR) ∧
    ¬ (CL IN [1,3])) THEN
    BEGIN LOF := FALSE ; LCST := VAL END ELSE
    BEGIN IF TYPTR ≠ NIL THEN
      IF TYPTR^.FORM IN [ARRAYS,RECORDS] THEN
      BEGIN IF ACCESS = DRCT THEN
        BEGIN RP := RP + 1 ; IF RP = 6 THEN ERROR(33) END ;
        DPLMT := DPLMT - 1 ; LOADADR(GATTR,RP) ;
      END ELSE TRANSFER(GATTR,RP)
    END ;
    WITH LATTR DO
    BEGIN TYPTR := GATTR.TYPTR ; KIND := LCOND END ;
    LRELOPCL := CL ; INSYMBOL ; SIMPLEEXP ;
    IF (LATTR.TYPTR ≠ NIL) ∧ (GATTR.TYPTR ≠ NIL) THEN
    BEGIN WITH GATTR DO
      IF (KIND = SVAL) ∧ (VAL = 0) ∧ (TYPTR ≠ BOOLPTR) ∧
      ¬ (LRELOPCL IN [2,4]) ∧ LOF THEN LOF := FALSE ELSE
      BEGIN IF TYPTR^.FORM IN [RECORDS,ARRAYS] THEN
        BEGIN DPLMT := DPLMT - 1 ; LOADADR(GATTR,6) ;
          IF ACCESS = DRCT THEN RP := RP + 1 ;
        END ELSE TRANSFER(GATTR,RP)
      END ;
      IF LOF THEN
      BEGIN RP1 := RP ; RP := RP - 1 END ;
      IF LRELOPCL = 7 THEN →IN↓
      BEGIN IF (GATTR.TYPTR^.FORM = POWER) ∧ (GATTR.TYPTR^.ELSET =
        LATTR.TYPTR) ∨ (GATTR.TYPTR = PNUMPTR) ∧ (LATTR.TYPTR^.FORM =
        NUMERIC) THEN
        BEGIN IF LOF THEN
          BEGIN GEN15(63B,7,RP,0) ; GEN15(23B,RP,7,RP1) ;
            GEN15(20B,RP,0,59) ;
          END ELSE GEN15(20B,RP,0,59-LCST) ;
          WITH LATTR DO
          BEGIN JMP := 2 ; ARITH := TRUE END ;
        END ELSE ERROR(50)
      END →IF LRELOPCL = 7↓ ELSE
      BEGIN IF (LATTR.TYPTR = BOOLPTR) ∧ (GATTR.TYPTR = BOOLPTR) THEN
        BEGIN CASE LRELOPCL OF
         1: BEGIN GEN15(15B,RP,RP1,RP) ; LATTR.JMP := 0 END ;
         2: BEGIN GEN15(15B,RP,RP,RP1) ; LATTR.JMP := 1 END ;
         3: BEGIN GEN15(15B,RP,RP1,RP) ; LATTR.JMP := 1 END ;
         4: BEGIN GEN15(15B,RP,RP,RP1) ; LATTR.JMP := 0 END ;
         5: BEGIN GEN15(13B,RP,RP,RP1) ; LATTR.JMP := 0 END ;
         6: BEGIN GEN15(13B,RP,RP,RP1) ; LATTR.JMP := 1 END
        END →CASE↓ ;
        LATTR.ARITH := FALSE
      END →IF↓ ELSE
      BEGIN BT1 := LATTR.TYPTR^.FORM = NUMERIC ;
        BT2 := GATTR.TYPTR^.FORM = NUMERIC ;
        IF BT1 ∧ (GATTR.TYPTR = REALPTR) THEN
        BEGIN IF LOF THEN PACKANDNORM(RP) ;
          LATTR.TYPTR := REALPTR
        END ;
        IF BT2 ∧ (LATTR.TYPTR = REALPTR) THEN
        BEGIN IF LOF THEN PACKANDNORM(RP1) ;
          GATTR.TYPTR := REALPTR
        END ;
        IF BT1 ∧ BT2 ∨ (LATTR.TYPTR = GATTR.TYPTR) ∧ (LATTR.TYPTR^.FORM
        ≤ POINTER) ∨ (LATTR.TYPTR^.FORM = POINTER) ∧ (GATTR.TYPTR =
        NILPTR) ∨ (GATTR.TYPTR^.FORM = POINTER) ∧ (LATTR.TYPTR =
        NILPTR) THEN
        BEGIN IF LATTR.TYPTR = REALPTR THEN IT := 31B ELSE IT := 37B ;
          CASE LRELOPCL OF
       1: BEGIN IF LOF THEN GEN15(IT,RP,RP,RP1) ; LATTR.JMP := 2
          END ;
       2: BEGIN IF LOF THEN GEN15(IT,RP,RP1,RP) ; LATTR.JMP := 3
          END ;
       3: BEGIN IF LOF THEN GEN15(IT,RP,RP,RP1) ; LATTR.JMP := 3
          END ;
       4: BEGIN IF LOF THEN GEN15(IT,RP,RP1,RP) ; LATTR.JMP := 2
          END ;
       5: BEGIN IF LOF THEN GEN15(37B,0,RP,RP1)
                       ELSE BXIXJ(0,RP) ;
            LATTR.JMP := 0
          END ;
       6: BEGIN IF LOF THEN GEN15(37B,0,RP,RP1)
                       ELSE BXIXJ(0,RP) ;
            LATTR.JMP := 1
          END ;
          END →CASE↓ ;
          LATTR.ARITH := TRUE
        END →IF BT1 AND BT2 OR (...↓ ELSE
        IF (LATTR.TYPTR^.FORM = POWER) ∧ (GATTR.TYPTR^.FORM =
        POWER) THEN
        BEGIN IF (LATTR.TYPTR = GATTR.TYPTR) ∨ (LATTR.TYPTR = LAMPTR)
          ∨ (GATTR.TYPTR = LAMPTR) THEN
          BEGIN CASE LRELOPCL OF
       1, 4: ERROR(88) ;
          2: BEGIN IF LOF THEN GEN15(15B,0,RP,RP1) ELSE ERROR(89) ;
               LATTR.JMP := 1
             END ;
          3: BEGIN IF LOF THEN GEN15(15B,0,RP1,RP) ELSE ERROR(89) ;
               LATTR.JMP := 1
             END ;
       5, 6: BEGIN IF LOF THEN GEN15(13B,0,RP,RP1)
                          ELSE BXIXJ(0,RP) ;
               LATTR.JMP := LRELOPCL - 5
             END ;
            END →CASE↓ ;
            LATTR.ARITH := TRUE
          END ELSE ERROR(50)
        END →IF (LATTR...↓ ELSE
        IF (LATTR.TYPTR = GATTR.TYPTR) ∧ ((LATTR.TYPTR^.FORM =
        RECORDS) ∨ (LATTR.TYPTR^.FORM = ARRAYS)) THEN
        BEGIN IF LRELOPCL ≤ 4 THEN ERROR(94) ELSE
          BEGIN IF RP ≥ 4 THEN ERROR(33) ;
            GEN30(61B,7,0,GATTR.TYPTR^.SIZE) ; NOOP ; AT := IC ;
            GEN15(53B,RP1,6,7) ; GEN15(53B,RP1+1,RP,7) ;
            GEN15(37B,0,RP1+1,RP1) ; GEN30(03B,1,0,IC+2) ;
            GEN30(61B,7,7,-1) ; GEN30(05B,7,0,AT) ; NOOP ;
            WITH LATTR DO
            BEGIN KIND := LCOND ; ARITH := TRUE ;
              JMP := LRELOPCL - 5
            END ;
          END
        END ELSE ERROR(50)
      END →IF <> BOOLPTRS↓ ;
    END →IF LRELOPCL <= 6↓
    END →IF TYPTRS <> NIL↓ ;
    LATTR.TYPTR := BOOLPTR ;
    GATTR := LATTR
  END →IF NO = 8↓
END →EXPRESSION↓ ;

→ ------------------------------------------------------------ ↓

PROCEDURE PASSPARAMS ;
→PERFORMS CODE GENERATION FOR PASSING PARAMETERS TO CALLED
 PROCEDURE AND JUMPING TO ITS ENTRY↓
VAR LPL,LPC,LDSP,IT2 : SHRTINT ; LPA,AT : ADDRESS; LPK,BT : BOOLEAN;
    LFP : CTP ;
BEGIN WITH CTPTR^ DO
  BEGIN LPA := PROCADDR ; LPL := PROCLEVEL ;
    LFP := FORMALS ; LPK := PROCKIND = ACTUAL
  END ;
  LDSP := 3 ; LPC := 0 ;
  IF NO = 9 THEN →(↓
  BEGIN REPEAT
    BEGIN IF LFP = NIL THEN
      BEGIN IF LPK THEN
        BEGIN ERROR(72) ; SKIP(49) ; GOTO 1 END ;
        BT := FALSE
      END ELSE
      BT := LFP^.KLASS = PROC ;
      INSYMBOL ;
      IF BT THEN →PROC/FCT TO BE PASSED↓
      BEGIN IF NO ≠ 1 THEN →ID↓ ERROR(11) ELSE
        BEGIN SEARCH ;
          IF CTPTR = NIL THEN
          BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
          IF CTPTR^.KLASS ≠ PROC THEN ERROR(60) ELSE
          BEGIN WITH CTPTR^ DO
            BEGIN PT := LFP^.PROCTYPE ;
              IF PROCTYPE ≠ CTPTR THEN →PARAM. IS FCT↓
              BEGIN IF (PT = LFP) ∨ (PROCTYPE ≠ PT) ∧ ((PROCTYPE^.FORM
                ≠ NUMERIC) ∨ (PT^.FORM ≠ NUMERIC)) THEN ERROR(60)
              END ELSE →PARAM. IS PROC↓
              IF PT ≠ LFP THEN ERROR(60) ;
              IF CTPTR ≤ PREDEFP THEN
              BEGIN ERROR(83) ; SKIP(49) ; GOTO 1 END ELSE
              IF CTPTR ≤ EXTPTR THEN  → SET BIT TO INFORM MONITOR ↓
              WITH PARMLIST DO EXTFLAGS := EXTFLAGS+[CTPTR^.SEGSIZE] ;
              IF PROCTYPE ≠ NIL THEN
              IF PROCKIND = ACTUAL THEN
              BEGIN PT := FORMALS ; IT1 := 0 ; IT2 := 0 ;
                WHILE PT ≠ NIL DO
                BEGIN IF (PT^.KLASS = VARS) ∧ (PT^.VKIND = FORMAL)
                  THEN APPEND(IT1,1,1) ELSE APPEND(IT1,1,0) ;
                  IT2 := IT2 + 1 ; PT := PT^.NXTEL
                END ;
                APPEND(IT1,17-IT2,0) ; IF IT2 > 17 THEN ERROR(103) ;
                GEN30(71B,6,0,PROCADDR) ;
                IF IT1 ≠ 0 THEN
                BEGIN GEN30(71B,0,0,IT1) ; GEN15(20B,0,0,43) ;
                  GEN15(12B,6,6,0) ;
                END ;
                IF PROCLEVEL ≠ 0 THEN
                BEGIN IF PROCLEVEL = LEVEL THEN GEN15(76B,1,5,0)
                  ELSE LOADBASE(1,PROCLEVEL) ;
                  GEN15(20B,1,0,18) ; GEN15(12B,6,6,1) ;
                END
              END ELSE
              BEGIN IF PROCLEVEL = LEVEL THEN
                GEN30(51B,1,5,PROCADDR) ELSE
                BEGIN LOADBASE(1,PROCLEVEL) ; GEN30(52B,1,1,PROCADDR)
                END ;
                GEN15(10B,6,1,0)
              END ;
            END →WITH CTPTR^↓
          END →IF CTPTR^.KLASS = PROC↓ ;
          INSYMBOL
        END →NO = 1↓
      END ELSE →EXPRESSION TO BE PASSED↓
      BEGIN
      B6DPL := LDSP ; EXPRESSION ;
      IF GATTR.TYPTR ≠ NIL THEN
      BEGIN IF LPK THEN
        BEGIN IF (LFP^.KLASS = KONST) ∨ (LFP^.VKIND = ACTUAL) THEN
          BEGIN IF GATTR.KIND = VARBL THEN
            BEGIN TRANSFER(GATTR,RP) ; GEN15(10B,6,RP,0) END
            ELSE TRANSFER(GATTR,6) ;
            IF LFP^.KLASS = KONST THEN PT := LFP^.CONTYPE
                                  ELSE PT := LFP^.VTYPE ;
            IF (GATTR.TYPTR^.FORM = NUMERIC) ∧ (PT = REALPTR) THEN
            BEGIN PACKANDNORM(6) ; GATTR.TYPTR := REALPTR END ;
          END ELSE
          BEGIN IF GATTR.KIND = VARBL THEN LOADADR(GATTR,6)
                                      ELSE ERROR(86) ;
            PT := LFP^.VTYPE
          END ;
          IF PT ≠ NIL THEN
          IF GATTR.TYPTR ≠ PT THEN
          IF (GATTR.TYPTR^.FORM ≠ NUMERIC) ∨ (PT^.FORM ≠ NUMERIC) THEN
          IF (GATTR.TYPTR ≠ NILPTR) ∨ (PT^.FORM ≠ POINTER) THEN
          IF (GATTR.TYPTR ≠ LAMPTR) ∨ (PT^.FORM ≠ POWER) THEN
          ERROR(60) ;
        END →IF LPK↓ ELSE
        BEGIN IF GATTR.KIND ≠ VARBL THEN TRANSFER(GATTR,6) ELSE
          BEGIN LOADADR(GATTR,1) ;
            IF LPL = LEVEL THEN GEN30(51B,2,5,LPA) ELSE
            BEGIN LOADBASE(2,LPL) ; GEN30(52B,2,2,LPA) END ;
            IF LPC ≠ 0 THEN GEN15(20B,2,0,LPC) ;
            IF CP = 1 THEN AT := IC ELSE AT := IC + 1 ;
            GEN30(03B,3,2,AT) ; GEN15(53B,1,1,0) ; NOOP ;
            GEN15(10B,6,1,0)
          END
        END ;
      END →IF GATTR.TYPTR <> NIL↓ ;
      END →EXP↓ ;
      GEN30(51B,6,6,LDSP) ;
      LDSP := LDSP + 1 ; LPC := LPC + 1 ; RP := 0 ;
      IF LPK THEN LFP := LFP^.NXTEL
    END
    UNTIL NO ≠ 15 ; →,↓
    IF NO ≠ 10 THEN →)↓ BEGIN ERROR(48) ; SKIP(49) END ELSE INSYMBOL
  END →IF NO = 9↓ ;
  IF LFP ≠ NIL THEN ERROR(72) ;
  IF LPK THEN
  BEGIN IF LPL ≠ 0 THEN
    BEGIN IF LPL = LEVEL THEN GEN15(76B,6,5,0) ELSE
      BEGIN LOADBASE(1,LPL) ; GEN15(10B,6,1,0) END
    END ;
    GEN30(71B,7,0,IC+1) ; GEN30(04B,0,0,LPA) ;
  END ELSE
  BEGIN IF LPL = LEVEL THEN GEN30(51B,1,5,LPA) ELSE
    BEGIN LOADBASE(1,LPL) ; GEN30(52B,1,1,LPA) END ;
    GEN15(63B,7,1,0) ; GEN15(20B,1,0,42) ;
    GEN15(73B,6,1,0) ; GEN30(71B,7,0,IC+1) ;
    GEN30(02B,7,0,0) ;
  END ;
  NOOP ;
1: B6DPL := 3
END →PASSPARAMS↓ ;

PROCEDURE ASSIGN ;
VAR LATTR : ATTR ; AT : ADDRESS;
BEGIN VARIABLE ; LATTR := GATTR ;
  IF NO ≠ 20 THEN →:=↓
  BEGIN IF GATTR.TYPTR ≠ NIL THEN ERROR(52) ; SKIP(20) ;
    IF NO ≠ 20 THEN
    BEGIN IF GATTR.TYPTR = NIL THEN ERROR(52) ; GOTO 1 END
  END ;
  INSYMBOL ; EXPRESSION ;
  IF GATTR.TYPTR = NIL THEN SKIP(49) ELSE
  IF LATTR.TYPTR ≠ NIL THEN
  BEGIN WITH GATTR DO
    IF TYPTR^.FORM ≥ ARRAYS THEN
    BEGIN DPLMT := DPLMT - 1 ; LOADADR(GATTR,2) ; RP := 2 END ELSE
    IF (KIND = LVAL) ∧ (CTERM ≠ 0) THEN
    WITH LATTR.TYPTR^ DO
    IF (FORM = NUMERIC) ∧ (ABS(MIN) < TWOTO17) ∧ (ABS(MAX) < TWOTO17) THEN
    GEN30(72B,6,RP,CTERM) ELSE TRANSFER(GATTR,6) ELSE
    IF KIND = VARBL THEN
    BEGIN TRANSFER(GATTR,RP) ; GEN15(10B,6,RP,0) END ELSE
    TRANSFER(GATTR,6) ;
    IF GATTR.KIND ≠ SVAL THEN RP := RP - 1 ;
    IF (LATTR.TYPTR = REALPTR) ∧ (GATTR.TYPTR^.FORM = NUMERIC) THEN
    PACKANDNORM(6) ELSE
    IF LATTR.TYPTR ≠ GATTR.TYPTR THEN
    IF (LATTR.TYPTR^.FORM ≠ NUMERIC) ∨ (GATTR.TYPTR^.FORM ≠ NUMERIC)
    THEN
    IF (LATTR.TYPTR^.FORM ≠ POINTER) ∨ (GATTR.TYPTR ≠ NILPTR) THEN
    IF (LATTR.TYPTR^.FORM ≠ POWER) ∨ (GATTR.TYPTR ≠ LAMPTR) THEN
    ERROR(53) ;
    WITH LATTR.TYPTR^ DO
    IF FORM ≤ POWER THEN
    BEGIN IF (FORM = NUMERIC) ∧ (LATTR.TYPTR ≠ INTPTR) THEN
      BEGIN WITH GATTR DO
        IF KIND = SVAL THEN
        BEGIN IF (MIN > VAL) ∨ (MAX < VAL) THEN ERROR(101) ;
        END ELSE
        IF ASSCHECK THEN CHECKBNDS(6,MIN,MAX,ASSERR)
      END ELSE
      IF (FORM = SYMBOLIC) ∧ (LATTR.TYPTR ≠ REALPTR)
      ∧ (LATTR.TYPTR ≠ ALFAPTR) ∧ (GATTR.KIND ≠ SVAL) ∧ ASSCHECK THEN
      CHECKBNDS(6,0,FCONST^.VALUES,ASSERR) ;
      TRANSFER(LATTR,6)
    END ELSE
    IF FORM ≥ CLASSS THEN ERROR(53) ELSE
    BEGIN LATTR.DPLMT := LATTR.DPLMT - 1 ; LOADADR(LATTR,1) ;
      GEN30(61B,7,0,SIZE) ; NOOP ; AT := IC ;
      GEN15(53B,3,2,7) ; GEN15(10B,6,3,0) ; GEN15(53B,6,1,7) ;
      GEN30(61B,7,7,-1) ; GEN30(05B,0,7,AT)
    END
  END →IF LATTR.TYPTR = NIL↓ ;
1:END →ASSIGN↓ ;

PROCEDURE VARIAB ;
BEGIN IF NO ≠ 1 THEN
  BEGIN ERROR(49) ; GATTR.TYPTR := NIL END ELSE
  BEGIN SEARCH ;
    IF CTPTR = NIL THEN
    BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
    IF CTPTR^.KLASS ≤ PROC THEN
    BEGIN ERROR(32) ; INSYMBOL ; GATTR.TYPTR := NIL END
    ELSE VARIABLE
  END
END →VARIAB↓ ;

PROCEDURE TITLE ;
  CONST TXT = 112B ;
  VAR I, LCA, LCP : SHRTINT ; AWORD : ALFA ;
      A : ARRAY [1..ALFALENG] OF CHAR ;
BEGIN WHILE CH = ≡ ≡ DO NEXTCH ;
  IF CH ≠ ≡≡≡≡ THEN
  BEGIN INSYMBOL ; ERROR(44) ; SKIP(49) ; GOTO 10 END ;
  GEN30(71B,7,0,0) ; LCA := CA ; LCP := CP ;
  GEN30(71B,1,0,IC+1) ; GEN30(04B,0,0,TXT) ;
  NOOP ; CODE[CA] := BUF ; I := 0 ; NEXTCH ;
  WHILE (CH ≠ ≡≡≡≡) ∧ ¬ EOLFLAG DO
  BEGIN I := I + 1 ; A[I] := CH ;
    IF I = ALFALENG THEN
    BEGIN PACK(A,1,AWORD) ; I := 0 ;
      CA := CA + 1 ; IC := IC + 1 ;
      IF CA > CODMAX THEN
      BEGIN ERROR(90) ; CA := 1 END ;
      CODE[CA] := INT(AWORD)
    END ;
    NEXTCH
  END ;
  IF EOLFLAG THEN
  BEGIN ERROR(44) ; INSYMBOL ; SKIP(49) ; GOTO 10 END ;
  FOR I := I + 1 TO ALFALENG DO A[I] := EOL ;
  PACK(A,1,AWORD) ; BUF := INT(AWORD) ;
  CA := CA + 1 ; IC := IC + 1 ; INS(IC,LCP,LCA) ;
  IF CA > CODMAX THEN
  BEGIN ERROR(90) ; CA := 1 END ;
  NEXTCH ; INSYMBOL ;
  IF NO ≠ 10 THEN
  BEGIN ERROR(48) ; SKIP(49) END ELSE INSYMBOL ;
10:END →TITLE↓ ;

PROCEDURE GETPUT(LPSW : SHRTINT) ;
   CONST EOR = 107B, GETB = 113B, PUTB = 102B, REST = 106B ;
BEGIN
   IF NO ≠ 9 THEN  → SY <> ( ↓
   BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; VARIAB ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   BEGIN
      IF TYPTR^.FORM = FILES THEN
      BEGIN
         DPLMT := DPLMT + 1 ;
         IF ACCESS = DRCT THEN
         BEGIN IF BREG IN [0,LEVEL] THEN
            BEGIN IF BREG ≠ 0 THEN BREG := 5 ;
               GEN30(61B,7,BREG,DPLMT)
            END ELSE
            BEGIN LOADBASE(5,BREG) ; GEN30(62B,7,5,DPLMT) END ;
         END ELSE GEN30(62B,7,RP,DPLMT) ;
         CASE LPSW OF
           →EOR↓ 1: JUMPTO(EOR) ;
           →GET↓ 2: IF TYPTR^.FELTYPE = CHARPTR THEN JUMPTO(GETC)
                                                  ELSE JUMPTO(GETB) ;
           →PUT↓ 3: IF TYPTR^.FELTYPE = CHARPTR THEN JUMPTO(PUTC)
                                                  ELSE JUMPTO(PUTB) ;
           →RST↓ 4: JUMPTO(REST)
         END ;
      END ELSE
      IF (TYPTR^.FORM = POINTER) ∧ (LPSW=4) THEN
      BEGIN
         TRANSFER(GATTR,RP) ; GEN15(10B,6,RP,0) ;
         RP := RP - 1 ; ADDRESSVAR(TYPTR^.DOMAIN,GATTR) ;
         TRANSFER(GATTR,6)
      END ELSE ERROR(44) ;
   END ;
   IF NO ≠ 10 THEN  → SY <> ) ↓
   BEGIN ERROR(48) ; SKIP(49) ; END ELSE INSYMBOL ;
10:   END → GETPUT ↓ ;

PROCEDURE ALLC ;
   VAR BT1 : BOOLEAN ; LATTR : ATTR ;
BEGIN
   IF NO ≠ 9 THEN  → SY <> ( ↓
   BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL; VARIAB; PT := NIL;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   WITH TYPTR^ DO
   IF FORM ≠ POINTER THEN ERROR(44) ELSE
   BEGIN
      ADDRESSVAR(DOMAIN,LATTR) ; TRANSFER(LATTR,RP) ;
      IT1 := DOMAIN^.VTYPE^.SIZE ; PT := ELTYPE ;
      END ;
      IF PT = NIL THEN
      BEGIN SKIP(49);  GOTO 10  END;
      IF NO = 15 THEN  → SY = , ↓
      BEGIN
         PT := PT^.RECVAR;
         REPEAT
            IF PT = NIL THEN
            BEGIN ERROR(66);  SKIP(49);  GOTO 10  END;
            INSYMBOL;
            IF NO = 1 THEN
            BEGIN SEARCH;
               IF CTPTR = NIL THEN
               BEGIN ERROR(31);  SKIP(49);  GOTO 10 END;
               IF CTPTR^.KLASS ≠ KONST THEN
               BEGIN ERROR(63);  SKIP(49);  GOTO 10 END;
               WITH PT^ DO
               IF (CASETYPE^.FORM = SYMBOLIC) ∧
                   (CTPTR^.CONTYPE ≠ CASETYPE)  ∨
                 (CASETYPE^.FORM = NUMERIC) ∧
                   (CTPTR^.CONTYPE ≠ INTPTR) THEN
               BEGIN ERROR(73);  SKIP(49);  GOTO 10 END;
               IVAL := CTPTR^.VALUES;
            END ELSE
            IF (NO ≠ 2) ∨ (CL IN [2,3]) THEN
            BEGIN ERROR(63);  SKIP(49);  GOTO 10 END ELSE
            WITH PT^ DO
            IF (CL = 1) ∧ (CASETYPE^.FORM ≠ NUMERIC)
               ∨ (CL = 4) ∧ (CASETYPE ≠ CHARPTR) THEN
            BEGIN ERROR(73);  SKIP(49);  GOTO 10 END;
            CTPTR := PT^.VARIANTS;  BT1 := FALSE;
            WHILE (CTPTR ≠ NIL) ∧ ¬ BT1 DO
            WITH CTPTR^ DO
               IF CASEVAL = IVAL THEN BT1 := TRUE
                                 ELSE CTPTR := NXTEL;
            IF CTPTR = NIL THEN
            BEGIN IT := PT^.CASESIZE;  PT := NIL END ELSE
            BEGIN IT := CTPTR^.CASESIZE;  PT := CTPTR^.VARIANTS END;
            INSYMBOL;
         UNTIL NO ≠ 15;
      END ELSE IT := PT^.SIZE;
      GEN30(72B,6,RP,IT) ; GEN15(54B,6,RP,0) ;
      GEN30(70B,0,RP,IT1) ; GEN15(37B,0,0,6) ;
      GEN15(10B,6,RP,0) ; GEN30(03B,2,0,IC + (CP+1) DIV 2) ;
      GEN15(54B,6,RP,0) ; GEN30(71B,6,0,NILVAL) ;
      NOOP ; RP := RP - 1 ; TRANSFER(GATTR,6) ;
      IF NO ≠ 10 THEN  → SY <> ) ↓
      BEGIN ERROR(48) ; SKIP(49) END ELSE INSYMBOL ;
10:   END → ALLC ↓ ;

PROCEDURE PCK ;
   VAR LPT : CTP ; LLO, LHI : SHRTINT ;
BEGIN
   IF NO ≠ 9 THEN  → SY <> ( ↓
   BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; VARIAB ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   BEGIN
      WITH TYPTR^ DO
      IF (FORM ≠ ARRAYS) ∨ (AELTYPE ≠ CHARPTR) THEN ERROR(44) ELSE
      BEGIN LPT := INXTYPE ; DPLMT := DPLMT + (ALFALENG-1) - LO ;
         LLO := LO ; LHI := HI - (ALFALENG - 1) ;
      END ;
      LOADADR(GATTR,1) ; RP := 1 ;
   END ELSE LPT := INTPTR;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; EXPRESSION ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   BEGIN
      IF (TYPTR^.FORM ≠ NUMERIC) ∨ (LPT^.FORM ≠ NUMERIC) THEN
      BEGIN IF TYPTR ≠ LPT THEN ERROR(44) END ELSE
      BEGIN
         TRANSFER(GATTR,2) ; RP := 2 ;
         IF INXCHECK THEN CHECKBNDS(2,LLO,LHI,INXERR) ;
         GEN15(36B,0,1,2) ;
         GEN30(61B,7,0,-ALFALENG) ; GEN15(13B,6,0,0) ;
         NOOP ; IT := IC ;
         GEN30(61B,7,7,1) ; GEN15(53B,1,0,7) ;
         GEN15(20B,6,0,6) ; GEN15(12B,6,1,6) ;
         GEN30(05B,7,0,IT) ; RP := 0
      END ;
   END ;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; VARIAB ;
   IF GATTR.TYPTR ≠ NIL THEN
      IF GATTR.TYPTR ≠ ALFAPTR THEN ERROR(44)
                                ELSE TRANSFER(GATTR,6) ;
   IF NO ≠ 10 THEN  → SY <> ) ↓
   BEGIN ERROR(48) ;SKIP(49) ; END ELSE INSYMBOL ;
10:   END → PCK ↓ ;

PROCEDURE UNPCK ;
   VAR LPT : CTP ; LLO, LHI : SHRTINT ;
BEGIN
   IF NO ≠ 9 THEN  → SY <> ( ↓
   BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; EXPRESSION ;
   IF GATTR.TYPTR ≠ NIL THEN
      IF GATTR.TYPTR ≠ ALFAPTR THEN ERROR(44)
                                ELSE TRANSFER(GATTR,1) ;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; VARIAB ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   BEGIN
      WITH TYPTR^ DO
      IF (FORM ≠ ARRAYS) ∨ (AELTYPE ≠ CHARPTR) THEN ERROR(44) ELSE
      BEGIN LPT := INXTYPE ; DPLMT := DPLMT + (ALFALENG-1) - LO ;
      LLO := LO ; LHI := HI - (ALFALENG - 1) ;
      END ;
      LOADADR(GATTR,2) ; RP := 2 ;
   END ELSE LPT := INTPTR;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; EXPRESSION ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
   BEGIN
      IF (TYPTR^.FORM ≠ NUMERIC) ∨ (LPT^.FORM ≠ NUMERIC) THEN
      BEGIN IF TYPTR ≠ LPT THEN ERROR(44) END ELSE
      BEGIN
         TRANSFER(GATTR,3) ; RP := 3 ;
         IF INXCHECK THEN CHECKBNDS(3,LLO,LHI,INXERR) ;
         GEN15(36B,2,2,3) ;
         GEN30(61B,7,0,-ALFALENG) ; GEN15(43B,0,0,54) ;
         NOOP ; IT := IC ;
         GEN30(61B,7,7,1) ; GEN15(20B,1,0,6) ;
         GEN15(15B,6,1,0) ; GEN15(53B,6,2,7) ;
         GEN30(05B,7,0,IT) ;
      END
   END ;
   IF NO ≠ 10 THEN  → SY <> ) ↓
   BEGIN ERROR(48) ;SKIP(49) ; END ELSE INSYMBOL ;
10:   END → UNPCK ↓ ;

PROCEDURE INSAPP(LPSW : SHRTINT) ;
VAR LVALUE : SHRTINT ; LOF : BOOLEAN ;
BEGIN
   IF NO ≠ 9 THEN  → SY <> ( ↓
   BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ;
   IF LPSW = 8 THEN EXPRESSION ELSE VARIAB ;
   IF GATTR.TYPTR ≠ NIL THEN
      IF GATTR.TYPTR^.FORM ≠ NUMERIC THEN ERROR(44)
                                      ELSE TRANSFER(GATTR,1) ;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ; EXPRESSION ;
   LOF := FALSE ;
   WITH GATTR DO
   IF TYPTR ≠ NIL THEN
      IF TYPTR^.FORM ≠ NUMERIC THEN ERROR(44) ELSE
      IF KIND = SVAL THEN
      BEGIN LOF := TRUE ; LVALUE := VAL ; RP := 2 END
      ELSE TRANSFER(GATTR,2) ;
   IF NO ≠ 15 THEN
   BEGIN ERROR(80) ; SKIP(49) ; GOTO 10 END ;
   INSYMBOL ;
   IF LPSW = 8 THEN VARIAB ELSE EXPRESSION ;
   IF GATTR.TYPTR ≠ NIL THEN
      IF GATTR.TYPTR^.FORM ≠ NUMERIC THEN ERROR(44)
                                      ELSE TRANSFER(GATTR,3) ;
   IF LOF THEN
   BEGIN IF LVALUE ≠ 0 THEN GEN15(20B,1,0,LVALUE) END ELSE
   BEGIN GEN15(63B,7,2,0) ; GEN15(22B,1,7,1) END ;
   GEN15(12B,6,1,3) ;
   IF LPSW = 8 THEN GEN15(54B,6,3,0) ELSE GEN15(54B,6,1,0) ;
   IF NO ≠ 10 THEN  → SY <> ) ↓
   BEGIN ERROR(48) ; SKIP(49) ; END ELSE INSYMBOL ;
10:   END → INSAPP ↓ ;

PROCEDURE READIR;
   CONST RD = 110B ;
BEGIN IF NO ≠ 9 THEN → ( ↓
   BEGIN ERROR(79);  SKIP(49);  GOTO 10  END;
   REPEAT
      INSYMBOL;  VARIAB;
      IF GATTR.TYPTR ≠ NIL THEN
         IF GATTR.TYPTR = CHARPTR THEN
         BEGIN → INLINE CODE ↓
            IF GATTR.ACCESS ≠ DRCT THEN
            BEGIN GEN15(10B,6,1,0) ; IT := LC + TCT ;
               IF TCT = TMAX THEN TMAX := TMAX + 1 ;
               GEN30(51B,6,5,IT) ;
            END ;
            GEN30(61B,7,0,INPT+1);  JUMPTO(GETC) ;
            GEN30(51B,1,0,INPT);  GEN15(53B,1,1,0);
            GEN15(10B,6,1,0);
            IF GATTR.ACCESS ≠ DRCT THEN GEN30(51B,1,5,IT);
            TRANSFER(GATTR,6);
         END ELSE
         BEGIN LOADADR(GATTR,1) ;
            IF GATTR.TYPTR^.FORM = NUMERIC THEN
               GEN15(66B,7,0,0)  ELSE
            IF GATTR.TYPTR = REALPTR THEN
               GEN30(61B,7,0,1)  ELSE ERROR(44) ;
            JUMPTO(RD) ;
         END;  RP := 0;
   UNTIL NO ≠ 15 → , ↓ ;
   IF NO ≠ 10 THEN → ) ↓
   BEGIN ERROR(48);  SKIP(49)  END ELSE INSYMBOL ;
10:   END →READIR↓ ;

   PROCEDURE WRITEIR ;
      CONST WRTI=114B,WRTE=115B,WRTF=116B,WRTA=117B,WRTC=120B,WRTB=121B,
            WRTO=111B;
      VAR LPTR : CTP ; LX2 : BOOLEAN ;
      PROCEDURE SETX2ANDJMP(FDEFVAL : INTEGER; FADR : ADDRESS) ;
      BEGIN IF LX2 THEN GEN30(71B,2,0,FDEFVAL) ;
         JUMPTO(FADR)
      END ;
      PROCEDURE LOADEXP ;
      BEGIN INSYMBOL ; EXPRESSION ;
         IF GATTR.TYPTR ≠ NIL THEN
            IF GATTR.TYPTR^.FORM ≠ NUMERIC THEN ERROR(62) ;
         TRANSFER(GATTR,RP)
      END ;
   BEGIN IF NO ≠ 9 THEN →(↓
      BEGIN ERROR(79) ; SKIP(49) ; GOTO 10 END ;
      REPEAT INSYMBOL ; EXPRESSION ; TRANSFER(GATTR,RP) ;
         LPTR := GATTR.TYPTR ;
         IF NO = 19 THEN →:↓
         BEGIN LOADEXP ; LX2 := FALSE ;
         END ELSE LX2 := TRUE ; →X2 NOT YET SET↓
         IF LPTR ≠ NIL THEN
         IF (NO=1) ∧ (AVAL=≡OCT≡) ∧ (LPTR^.FORM≤POWER) THEN →O-FORMAT↓
         BEGIN SETX2ANDJMP(20,WRTO) ; INSYMBOL END ELSE
         IF LPTR^.FORM = NUMERIC THEN SETX2ANDJMP(10,WRTI) ELSE
         IF LPTR = REALPTR THEN
         BEGIN IF NO = 19 THEN →:↓
            BEGIN LOADEXP ;
               SETX2ANDJMP(20,WRTF)
            END ELSE SETX2ANDJMP(20,WRTE) ;
         END ELSE
         IF LPTR = ALFAPTR THEN SETX2ANDJMP(10,WRTA) ELSE
         IF LPTR = BOOLPTR THEN SETX2ANDJMP(10,WRTB) ELSE
         IF LPTR = CHARPTR THEN
         BEGIN IF LX2 THEN →CALL PUTC ONLY↓
            BEGIN BXIXJ(6,1) ;
               GEN30(51B,1,0,OUTPT) ; GEN15(53B,6,1,0) ;
               GEN30(61B,7,0,OUTPT+1) ; JUMPTO(PUTC)
            END ELSE JUMPTO(WRTC)
         END ELSE ERROR(44) ;   RP := 0 ;
      UNTIL NO ≠ 15 ; →,↓
      IF NO ≠ 10 THEN →)↓
      BEGIN ERROR(48) ; SKIP(49) END ELSE INSYMBOL ;
10:   END →WRITEIR↓ ;

   PROCEDURE IFSTAT ;
   VAR LCA1, LCA2, LCP1, LCP2: SHRTINT ;
   BEGIN
      INSYMBOL ; EXPRESSION ;
      IF GATTR.TYPTR ≠ NIL THEN GENJP(0) ;
      LCA1 := CA ; LCP1 := CP ;
      IF NO ≠ 24 THEN  → SY <> THEN ↓
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(56) ; SKIP(24) ;
         IF NO ≠ 24 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(56) ;
            IF ERRCL[NO] = ENDSY THEN GOTO 30 ; GOTO 20 ;
         END
      END ;
      INSYMBOL ;
20:   STATEMENT ;
30:   IF NO ≠ 25 THEN  → SY <> ELSE ↓
      BEGIN NOOP; INS(IC,LCP1,LCA1)  END ELSE
      BEGIN
         GEN30(04B,0,0,0) ;
         LCA2 := CA ; LCP2 := CP ;
         NOOP ;
         INS(IC,LCP1,LCA1);
         INSYMBOL ; STATEMENT ;
         NOOP;  INS(IC,LCP2,LCA2);
      END
   END → IFSTAT ↓ ;


PROCEDURE CASESTAT ;
TYPE PTR = ^LCSLABS ;
VAR LCSLABS : CLASS   30   OF PACKED RECORD NEXT : PTR ;
                                  CSLAB : SHRTINT ;
                                  ADDR : ADDRESS ;
                              END ;
    LCA, LCP, LCA1, LCP1, LCA2, LCP2, LMIN, LMAX : SHRTINT ;
      LPTR, PT1, PT2 : PTR ; LCTP : CTP ; LERR : BOOLEAN ;

PROCEDURE ACASE ;
VAR LCA,LCP : SHRTINT ; LERRFG : BOOLEAN ; PT1,PT2,PT3 : PTR ;
BEGIN LERRFG := TRUE ; NOOP ;
  REPEAT IF NO IN [15,27] THEN →, OF↓ INSYMBOL ;
    IF NO = 1 THEN →ID↓
    BEGIN SEARCH ;
      IF CTPTR = NIL THEN
      BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
      WITH CTPTR^ DO
      BEGIN IF KLASS ≠ KONST THEN
        BEGIN IF LERRFG THEN ERROR(61) ; GOTO 1 END ;
        IF CONTYPE ≠ NIL THEN
        BEGIN IF CONKIND = FORMAL THEN
          BEGIN ERROR(61) ; GOTO 1 END ;
          IF LCTP = NIL THEN LCTP := CONTYPE ELSE
          IF LCTP ≠ CONTYPE THEN ERROR(73) ;
          IT := VALUES ;
        END
      END
    END →IF NO = 1↓ ELSE
    IF NO = 2 THEN →CONST↓
    BEGIN CASE CL OF
      1: PT := INTPTR ;
      2: PT := REALPTR ;
      3: PT := ALFAPTR ;
      4: PT := CHARPTR ;
      END ;
      IF LCTP = NIL THEN LCTP := PT ELSE
      IF LCTP ≠ PT THEN ERROR(73) ;
      IT := IVAL ;
    END →IF NO = 2↓ ELSE
    BEGIN IF LERRFG THEN ERROR(61) ; GOTO 1 END ;
    IF IT ≥ TWOTO17 THEN ERROR(100) ;
    LERRFG := FALSE ; PT1 := LPTR ; PT2 := NIL ;
    IF ¬ ERR THEN
    WHILE PT1 ≠ NIL DO
    BEGIN IF PT1^.CSLAB ≥ IT THEN
      BEGIN IF PT1^.CSLAB = IT THEN ERROR(77) ; GOTO 3 END ;
      PT2 := PT1 ; PT1 := PT1^.NEXT ;
    END ;
    LMAX := IT ;
 3: ALLOC(PT3) ;
    IF PT3 ≠ NIL THEN
    BEGIN WITH PT3^ DO
      BEGIN NEXT := PT1 ; CSLAB := IT ; ADDR := IC END ;
      IF PT2 = NIL THEN
      BEGIN LPTR := PT3 ; LMIN := IT END ELSE PT2^.NEXT := PT3 ;
    END ELSE ERROR(71) ;
    INSYMBOL ;
  UNTIL NO ≠ 15 ; →,↓
  IF NO ≠ 19 THEN →:↓ ERROR(64) ELSE INSYMBOL ;
1: STATEMENT ; GEN30(04B,0,0,0) ; LCA := CA ; LCP := CP ;
  IF NO = 16 THEN →;↓
  BEGIN INSYMBOL ; IF NO ≠ 22 THEN ACASE END ELSE
  IF ERRCL[NO] = BEGSY THEN
  BEGIN ERROR(58) ; GOTO 1 END ELSE
  IF NO ≠ 22 THEN ERROR(68) ;
  INS(IC+LMAX-LMIN+1,LCP,LCA) ;
END →ACASE↓ ;

BEGIN →CASESTAT↓
  LMIN := 0 ; LMAX := 0 ; LPTR := NIL ; LERR := ERR ; ERR := FALSE ;
  INSYMBOL ; EXPRESSION ;
  LCTP := GATTR.TYPTR ;
  IF LCTP ≠ NIL THEN
  BEGIN IF LCTP^.FORM = NUMERIC THEN LCTP := INTPTR ELSE
    IF (LCTP^.FORM > SYMBOLIC) ∨ (LCTP = REALPTR) ∨ (LCTP = ALFAPTR) THEN
    BEGIN ERROR(62) ; LCTP := NIL END ;
    TRANSFER(GATTR,RP) ;
  END ;
  IF INXCHECK THEN
  BEGIN GEN30(71B,7,0,IC) ; GEN30(71B,2,0,0) ;
    LCA1 := CA ; LCP1 := CP ; GEN15(37B,0,1,2) ;
    GEN30(71B,2,0,0) ; LCA2 := CA ; LCP2 := CP ;
    GEN15(37B,2,2,1) ; GEN15(12B,2,2,0) ;
    GEN30(03B,3,2,INXERR)
  END ;
  GEN15(63B,7,1,0) ; GEN30(02B,7,0,0) ; LCA := CA ; LCP := CP ;
  IF NO ≠ 27 THEN →OF↓
  BEGIN IF LCTP ≠ NIL THEN ERROR(65) ; SKIP(27) ;
    IF NO ≠ 27 THEN
    IF LCTP = NIL THEN ERROR(65) ;
  END ;
  ACASE ; INS(IC-LMIN,LCP,LCA) ; PT1 := LPTR ;
  IF INXCHECK THEN
  BEGIN INS(LMIN,LCP1,LCA1) ; INS(LMAX,LCP2,LCA2) ; END ;
  IT := LMIN ; IT1 := IC + LMAX - LMIN + 1 ; NOOP ;
  IF ¬ ERR THEN
  WHILE PT1 ≠ NIL DO
  BEGIN WHILE PT1^.CSLAB ≠ IT DO
    BEGIN IF INXCHECK THEN
      BEGIN GEN30(71B,7,0,IC) ; GEN30(04B,0,0,INXERR) END ELSE
      BEGIN GEN30(04B,0,0,IT1) ; NOOP END ;
      IT := IT + 1
    END ;
    GEN30(04B,0,0,PT1^.ADDR) ; NOOP ;
    PT1 := PT1^.NEXT ; IT := IT + 1 ;
  END ;
  IF NO = 22 THEN →END↓ INSYMBOL ;
  ERR := ERR ∨ LERR ;
END →CASESTAT↓ ;

PROCEDURE REPEATSTAT ;
VAR LJPADDR: ADDRESS ;
BEGIN
   NOOP ; LJPADDR := IC ;
   REPEAT
   BEGIN
      INSYMBOL ;
20:   STATEMENT ;
      IF ERRCL[NO] = BEGSY THEN BEGIN ERROR(58) ; GOTO 20 END ;
      IF NO = 25 THEN →ELSE↓
      BEGIN ERROR(54) ; INSYMBOL ; GOTO 20 END
   END
   UNTIL NO ≠ 16 ; → SY <> ; ↓
   IF NO ≠ 29 THEN → SY <> UNTIL ↓ ERROR(67) ELSE
   BEGIN
      INSYMBOL ; EXPRESSION ;
      IF GATTR.TYPTR ≠ NIL THEN GENJP(LJPADDR) ELSE SKIP(49)
   END
END → REPEATSTAT ↓ ;

PROCEDURE WHILESTAT ;
VAR LJPADDR : ADDRESS;  LCA,LCP : SHRTINT;
   BEGIN
      NOOP ; LJPADDR := IC ;
      INSYMBOL ; EXPRESSION ;
      IF GATTR.TYPTR ≠ NIL THEN GENJP(0) ;
      LCA := CA ; LCP := CP ;
      IF NO ≠ 31 THEN  → SY <> DO ↓
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(59) ; SKIP(31) ;
         IF NO ≠ 31 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(59) ;
            IF ERRCL[NO] = BEGSY THEN GOTO 20 ; GOTO 10
         END
      END ;
      INSYMBOL ;
20:   STATEMENT ;
      GEN30(04B,0,0,LJPADDR) ;
10:   NOOP;  INS(IC,LCP,LCA);
   END → WHILESTAT ↓ ;

   PROCEDURE FORSTAT ;
   VAR LATTR : ATTR ; LCLASS, LCA, LCP : SHRTINT ;
      LJPADDR : ADDRESS ; LOF : BOOLEAN ; LUPBND : SHRTINT ;

   PROCEDURE CHTYPE ;
   BEGIN
      WITH GATTR DO
      IF TYPTR ≠ NIL THEN
      IF (TYPTR^.FORM > SYMBOLIC) ∨ (TYPTR = REALPTR) ∨
      (TYPTR = ALFAPTR) THEN
      BEGIN ERROR(62) ; TYPTR := NIL END
   END ;

   PROCEDURE CHTYPES ;
   BEGIN
      WITH GATTR DO
      IF (TYPTR ≠ NIL) ∧ (LATTR.TYPTR ≠ NIL) THEN
      IF((TYPTR^.FORM = SYMBOLIC) ∨ (LATTR.TYPTR^.FORM = SYMBOLIC)) ∧
      (TYPTR ≠ LATTR.TYPTR) THEN
      BEGIN ERROR(73) ; TYPTR := NIL END
   END ;

   BEGIN LCA := 0 ;
      INSYMBOL ;
      IF NO ≠ 1 THEN
      BEGIN ERROR(49) ; GATTR.TYPTR := NIL END ELSE
      BEGIN SEARCH ;
         IF CTPTR = NIL THEN
         BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
         IF CTPTR^.KLASS ≤ PROC THEN
         BEGIN ERROR(32) ; INSYMBOL END ELSE VARIABLE
      END ;
      CHTYPE ;
      IF GATTR.TYPTR ≠ NIL THEN
      WITH GATTR DO
      IF ACCESS ≠ DRCT THEN
      BEGIN ERROR(69) ; TYPTR := NIL END ELSE
      IF ¬ (BREG IN [0,LEVEL]) THEN ERROR(69) ;
      LATTR := GATTR ;
      IF NO ≠ 20 THEN  → SY <> := ↓
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(52) ; SKIP(20);
         IF NO ≠ 20 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(52) ;
            IF ERRCL[NO] = BEGSY THEN GOTO 20 ; GOTO 10
         END
      END ;
      INSYMBOL ; EXPRESSION ;
      CHTYPE ; CHTYPES ;
      TRANSFER(GATTR,RP) ;
      IF NO ≠ 33 THEN  → SY <> TO/DOWNTO ↓
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(70) ; SKIP(33) ;
         IF NO ≠ 33 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(70) ;
            IF ERRCL[NO] = BEGSY THEN GOTO 20 ; GOTO 10
         END
      END ;
      LCLASS := CL ;
      INSYMBOL ; EXPRESSION ;
      CHTYPE ; CHTYPES ;
      IF (GATTR.TYPTR ≠ NIL) ∧ (LATTR.TYPTR ≠ NIL) THEN
      BEGIN
         TRANSFER(GATTR,RP) ;
         IF GATTR.KIND = SVAL THEN
         BEGIN LOF := TRUE ; LUPBND := GATTR.VAL END ELSE
         BEGIN GEN15(10B,7,RP,0) ;
            GEN30(51B,7,5,LC+TCT) ; TCT := TCT + 1 ;
            IF TCT > TMAX THEN TMAX := TCT ; LOF := FALSE ;
         END ;
         GEN15(10B,6,1,0) ; NOOP ; LJPADDR := IC ;
         IF LCLASS = 1 THEN →STEP +1↓ GEN15(37B,1,2,6)
                       ELSE →STEP -1↓ GEN15(37B,1,6,2) ;
         GEN30(03B,3,1,0) ; LCA := CA ; LCP := CP ; RP := 0 ;
         IF ASSCHECK THEN
         WITH LATTR.TYPTR^ DO
         IF FORM = NUMERIC THEN
         BEGIN IF LATTR.TYPTR ≠ INTPTR THEN
            CHECKBNDS(6,MIN,MAX,ASSERR)
         END ELSE CHECKBNDS(6,0,FCONST^.VALUES,ASSERR) ;
         TRANSFER(LATTR,6) ;
      END ;
      IF NO ≠ 31 THEN  → SY <> DO ↓
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(59) ; SKIP(31) ;
         IF NO ≠ 31 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(59) ;
            IF ERRCL[NO] = BEGSY THEN GOTO 20 ; GOTO 10
         END
      END ;
      INSYMBOL ;
20:   STATEMENT ;
      IF LATTR.TYPTR ≠ NIL THEN
      BEGIN TRANSFER(LATTR,RP) ;
         WITH LATTR.TYPTR^ DO
         IF (FORM = NUMERIC) ∧ ((ABS(MIN) ≥ TWOTO17) ∨ (ABS(MAX) ≥
         TWOTO17)) THEN
         BEGIN GEN30(71B,0,0,1) ;
            GEN15(35B+LCLASS,6,1,0) ;  → +1 OR -1↓
         END ELSE GEN30(72B,6,1,3-2*LCLASS) ;
         IF LOF THEN GEN30(71B,2,0,LUPBND) ELSE
         BEGIN TCT := TCT - 1 ; GEN30(51B,2,5,LC+TCT) END ;
         GEN30(04B,0,0,LJPADDR) ; NOOP ;
         INS(IC,LCP,LCA);
      END ;
10:   END → FORSTAT ↓ ;

   PROCEDURE GOTOSTAT ;
   BEGIN INSYMBOL ;
         IF (NO = 1) ∧ (AVAL = ≡EXIT≡) THEN
         BEGIN INSYMBOL ;
            IF (NO ≠ 2) ∨ (CL ≠ 1) THEN
            BEGIN ERROR(61) ; SKIP(49) END ELSE
            BEGIN FOR IT := CEXTABIX DOWNTO 1 DO
                  IF EXTAB[IT].EXVAL = IVAL THEN
                  BEGIN IT1 := EXTAB[IT].JMPTABIX ;
                     IF JMPTAB[IT1] ≠ 0 THEN
                     BEGIN IF JMPTAB[IT1] ≠ LEVEL THEN
                        BEGIN LOADBASE(1,JMPTAB[IT1]) ; GEN15(63B,5,1,0)
                        END
                     END ELSE
                     BEGIN GEN30(51B,1,0,PARMLIST.ICO) ;
                        GEN15(63B,5,1,0)
                     END ;
                     GEN30(04B,0,0,PARMLIST.LPJMPTAB+IT1) ; GOTO 1
                  END ;
                  ERROR(43) ;
1:                INSYMBOL
            END
         END ELSE
         IF (NO ≠ 2) ∨ (CL ≠ 1) THEN
         BEGIN ERROR(61) ; SKIP(49) END ELSE
         BEGIN IF IVAL ≥ TWOTO17 THEN
            BEGIN ERROR(100) ; GOTO 20 END ;
            → SEARCH THROUGH LABELTABLE OF CURRENT BLOCK ↓
            FOR IT := 1 TO CLABIX DO
            WITH LABTAB[IT] DO
            BEGIN
               IF LABVAL = IVAL THEN  → LABEL ALREADY OCCURED ↓
               BEGIN
                  → IF DECL. OCC. GENERATE CODE ELSE CHAIN OCC. ↓
                  IF FLD2 = 0 THEN GEN30(04B,0,0,FLD3) ELSE
                  BEGIN
                     GEN30(04B,0,0,0) ;
                     IF CHNIX = 0 THEN
                     BEGIN ERROR(75) ; GOTO 20 END ;
                     WITH UNDLAB[CHNIX] DO
                     BEGIN
                        IT1 := SUCC ; SUCC := FLD3 ;
                        FLD3 := CHNIX ; PLACE := CA ;
                        LFTSH := CP ;
                     END ;
                     CHNIX := IT1
                  END ;
                  GOTO 20
               END
            END ;
            → LABEL NOT YET MET, ENTER IT INTO LABELTABLE ↓
            GEN30(04B,0,0,0) ;
            IF CLABIX = MAXLABS THEN BEGIN ERROR(74) ; GOTO 20 END ;
            IF CHNIX = 0 THEN BEGIN ERROR(75) ; GOTO 20 END ;
            CLABIX := CLABIX + 1 ;
            WITH LABTAB[CLABIX], UNDLAB[CHNIX] DO
            BEGIN
               IT1 := SUCC ; LABVAL := IVAL ;
               SUCC := 0 ; FLD2 := CHNIX ;
               FLD3 := CHNIX ; PLACE := CA ;
               LFTSH := CP
            END ;
            CHNIX := IT1 ;
20:         INSYMBOL ;
         END ;
   END → GOTOSTAT ↓ ;

   PROCEDURE WITHSTAT ;
   VAR LTPCT, LB7CT: SHRTINT ;
   BEGIN
      LTPCT := 0 ; LB7CT := 0 ;
      REPEAT
         INSYMBOL ;
         VARIAB ;
         WITH GATTR DO
         IF TYPTR ≠ NIL THEN
         IF TYPTR^.FORM ≠ RECORDS THEN ERROR(38) ELSE
         BEGIN
            TOP := TOP + 1 ; LTPCT := LTPCT + 1 ;
            IF TOP > DISPLIMIT THEN ERROR(82) ELSE
            WITH DISPLAY[TOP] DO
            BEGIN
               FNAME := TYPTR^.FSTFLD ;
               IF (ACCESS = DRCT) ∧ (BREG IN [0,LEVEL]) THEN
               BEGIN OCCUR := CWITH;
                  CDSPL := DPLMT;  CLEV := BREG;
               END ELSE
               BEGIN
                  LOADADR(GATTR,6) ; IT := LC + TCT ;
                  GEN30(51B,6,5,IT) ;
                  OCCUR := VWITH ; VDSPL := IT ;
                  TCT := TCT + 1 ; LB7CT := LB7CT + 1 ;
                  IF TCT > TMAX THEN TMAX := TCT ;
               END
            END
         END
      UNTIL NO ≠ 15 ; → SY <> , ↓
      IF NO ≠ 31 THEN
      BEGIN
         IF GATTR.TYPTR ≠ NIL THEN ERROR(59) ; SKIP(31) ;
         IF NO ≠ 31 THEN
         BEGIN
            IF GATTR.TYPTR = NIL THEN ERROR(59) ;
         IF ERRCL[NO] = BEGSY THEN GOTO 20 ; GOTO 10
         END
      END ;
      INSYMBOL ;
20:   STATEMENT ;
10:   TOP := TOP - LTPCT ; TCT := TCT - LB7CT ;
   END → WITHSTAT ↓ ;

→ ------------------------------------------------------------ ↓

PROCEDURE COMPSTAT ;
BEGIN REPEAT BEGIN
      INSYMBOL ;
1:    STATEMENT ;
      IF ERRCL[NO] = BEGSY THEN
   BEGIN ERROR(58) ; GOTO 1 END ;
   IF NO = 25 THEN →ELSE↓
   BEGIN ERROR(54) ; INSYMBOL ; GOTO 1 END
   END
 UNTIL NO ≠ 16 →;↓ ;
 IF NO ≠ 22 THEN →END↓ ERROR(68) ELSE INSYMBOL ;
END →COMPSTAT↓ ;

PROCEDURE STATEMENT ;
  VAR LPSW : SHRTINT;
BEGIN
  IF (NO = 2) ∧ (CL = 1) THEN →LABEL↓
  BEGIN NOOP ;
    IF IVAL ≥ TWOTO17 THEN
    BEGIN ERROR(100) ; GOTO 1 END ;
    FOR IT := 1 TO CLABIX DO
    WITH LABTAB[IT] DO
    IF LABVAL = IVAL THEN →FOUND↓
    BEGIN IF FLD2 = 0 THEN →MULTIDEF.↓ ERROR(77) ELSE →FIXUP↓
      BEGIN IT1 := FLD3 ;
        REPEAT WITH UNDLAB[IT1] DO
          BEGIN INS(IC,LFTSH,PLACE) ; IT1 := SUCC END
        UNTIL IT1 = 0 ;
        IT1 := FLD2 ; UNDLAB[IT1].SUCC := CHNIX ;
        CHNIX := FLD3 ; FLD2 := 0 ; FLD3 := IC ;
      END ;
      GOTO 1
    END →IF, WITH, FOR↓ ;
    →NEW LABEL↓
    IF CLABIX = MAXLABS THEN ERROR(74) ELSE
    BEGIN CLABIX := CLABIX + 1 ;
      WITH LABTAB[CLABIX] DO
      BEGIN LABVAL := IVAL ; FLD2 := 0 ; FLD3 := IC END ;
    END ;
1:  INSYMBOL ;
    IF NO ≠ 19 THEN →:↓
    BEGIN ERROR(64) ; SKIP(49) END ELSE INSYMBOL ;
  END →IF (NO=2) AND (CL=1)↓ ;
  RP := 0 ;
  CASE SPLITSTAT[NO] OF
  →PASS  ↓ 1: →ENDSY OR IRRELSY↓ ;
  →IDENT ↓ 2: BEGIN SEARCH ;
                  IF CTPTR = NIL THEN
                  BEGIN ERROR(31) ; CTPTR := UNDECPTR END ;
                  WITH CTPTR^ DO
                  IF KLASS ≤ KONST THEN ERROR(55) ELSE
                  IF (KLASS = PROC) ∧
                  ((PROCTYPE = CTPTR) ∨ (PROCTYPE = NIL)) THEN
                  BEGIN → PROCCALL ↓
                    IF PROCTYPE = CTPTR THEN
                    BEGIN INSYMBOL ; IF CTPTR ≤ PREDEFP THEN
                      BEGIN LPSW := CTPTR^.SEGSIZE ;
                       CASE LPSW OF
                  0:      TITLE ;
          1,2,3,4:        GETPUT(LPSW) ;
                  5:      ALLC ;
                  6:      PCK ;
                  7:      UNPCK ;
                8,9:      INSAPP(LPSW) ;
                 10:      READIR ;
                 11:      WRITEIR ;
                       END ;
                      END ELSE  PASSPARAMS ;
                    END ELSE SKIP(49)
                  END →PROCCALL↓ ELSE  ASSIGN ;
                END ;
  →BEGIN ↓ 3: COMPSTAT ;
  →IF    ↓ 4: IFSTAT ;
  →CASE  ↓ 5: CASESTAT ;
  →REPEAT↓ 6: REPEATSTAT ;
  →WHILE ↓ 7: WHILESTAT ;
  →FOR   ↓ 8: FORSTAT ;
  →GOTO  ↓ 9: GOTOSTAT ;
  →WITH  ↓ 10: WITHSTAT ;
  END ;
  IF ERRCL[NO] = IRRELSY THEN
  BEGIN ERROR(54) ; SKIP(49) END ;
  RP := 0
END →STATEMENT↓ ;

→ ------------------------------------------------------------ ↓

PROCEDURE TYPEDECL(VAR TL:SHRTINT; P1:CTP);
VAR I,L,LL,J,CV,E1,E2,BDISPL : SHRTINT;
   OPT : OPTPWR;  DISPL : ADDRESS;  PACKFLAG,LERR : BOOLEAN;
   LASTFLD,PP,P,NXTF,NXTC,NXTA,RTYP : CTP;

   PROCEDURE SKIPT(FNO : SHRTINT) ;
   BEGIN
      WHILE (TERRCL[NO] = IRRELSY) ∧ (FNO ≠ NO) DO INSYMBOL;
   END →SKIPT↓;

   PROCEDURE TYPERR(I : SHRTINT);
   BEGIN TL := 0;  P1 := NIL;
      ERROR(I);  SKIPT(49);
   END →TYPERR↓;

   PROCEDURE SUBRANGE(VAR VAL1,VAL2 : INTEGER; N1 : CTP;
      CONST P : CTP) ;
      →THE FIRST SYMBOL OF SUBRANGE HAS BEEN READ.
         THE PROCEDURE RETURNS THE TWO BOUND-VALUES IN VAL1,VAL2,
         AND RETURNS  N1 = POINTER TO TYPE OF CONSTANTS.
         ERRORS : TYPES DO NOT AGREE, TYPE IS NOT INTEGER,CHAR,
            OR SYMBOLIC,  VAL1 > VAL2.
         P INDICATES BEGINNING OF SEARCH FOR FIRST SYMBOL IF IT IS
         AN ID.  ↓
      VAR N2 : CTP;
   BEGIN INCONST(VAL1,N1,P);
      IF (N1=NIL) ∨ (N1=REALPTR) ∨ (N1=ALFAPTR) THEN
         ERR := TRUE ELSE
      BEGIN IF NO ≠ 19 THEN ERROR(10) ELSE INSYMBOL ;
         INCONST(VAL2,N2,NEXT);
         IF N1 ≠ N2 THEN ERR := TRUE ELSE
         IF VAL1 > VAL2 THEN ERROR(25);
      END;
   END →SUBRANGE↓;

   PROCEDURE SUBTYPE(VAR I,J : SHRTINT; P : CTP);
      →EITHER A TYPE-ID FOR A SUBRANGE OR AN EXPLICIT SUBRANGE
         ARE PROCESSED.
         RETURNS I = LOWBOUND, J = HIGHBOUND,
            P = POINTER TO TYPE OF CONSTANTS ↓
   BEGIN
      IF NO = 1 THEN
      BEGIN SRCHREC(NEXT);
         IF CTPTR = NIL THEN SEARCH;
         IF CTPTR = NIL THEN ERROR(12) ELSE
         BEGIN IF CTPTR^.KLASS = TYPES THEN
            BEGIN IF CTPTR^.FORM > SYMBOLIC THEN ERROR(13) ELSE
               BEGIN
                  CASE CTPTR^.FORM OF
   NUMERIC:          BEGIN I := CTPTR^.MIN;  J := CTPTR^.MAX;
                        P := INTPTR;
                     END;
   SYMBOLIC:         BEGIN IF (CTPTR = REALPTR) ∨ (CTPTR = ALFAPTR) THEN
                        ERROR(6) ELSE
                        BEGIN I := 0 ; J := CTPTR^.FCONST^.VALUES ;
                           P := CTPTR ;
                        END
                     END;
                  END →CASE↓;
                  INSYMBOL;
               END;
            END →TYPES↓ ELSE
            IF CTPTR^.KLASS = KONST THEN
               SUBRANGE(I,J,P,CTPTR) ELSE ERROR(63) ;
         END;
      END →ID↓ ELSE
      IF NO IN [2,7] THEN SUBRANGE(I,J,P,NIL) ELSE
         ERROR(1) ;
   END →SUBTYPE↓;

   PROCEDURE SCALDECL(N : CTP);
   BEGIN SUBRANGE(I,J,PP,N);
      IF ¬ ERR THEN
      IF PP^.FORM = SYMBOLIC THEN
      BEGIN ERROR(28);  P1 := NIL  END ELSE
      BEGIN ALLOC(P,TYPES,NUMERIC);
         WITH P^ DO
         BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
            SIZE := 1;  FORM := NUMERIC;
            MIN := I;  MAX := J;
            IF ABS(I) > ABS(J) THEN BITS := LOG2(ABS(I)) ELSE
                                    BITS := LOG2(ABS(J)) ;
         END;
         TL := 1;  P1 := P;
      END ELSE P1 := NIL
   END →SCALDECL↓;

PROCEDURE FIELDLIST(VAR MAXSIZE:SHRTINT; VARPTR,NXTF:CTP);
   VAR MXL,L,LL,MINSIZE,CASEBITS,I : SHRTINT;
      P,PP,PP1,PP2,NXTC,NXT,CPTR : CTP;
      TAGFLAG : BOOLEAN;

   PROCEDURE RECERR(I : SHRTINT);
   BEGIN ERROR(I);  SKIPT(49); END;

   PROCEDURE ADJUST;
      → MOVE LAST FIELD TO RIGHT. IF IT IS THE ONLY FIELD,
         CHANGE TO NONPACKED.
         IF LAST FIELD IS TAGFIELD THEN DO NOT MOVE.
         INCREASE DISPL, RESET BDISPL  ↓
   BEGIN IF ¬ TAGFLAG THEN
      WITH LASTFLD^ DO
      BEGIN IF BITDISPL = 0 THEN →ONLY ONE FIELD IN WORD↓
         BITWIDTH := 0 ELSE
         BITDISPL := WORDLENGTH - BITWIDTH;
      END;
      DISPL := DISPL + 1;  BDISPL := 0;
   END →ADJUST↓;

BEGIN
   TAGFLAG := TRUE;   NXT := NXTF;
   REPEAT
      IF NO = 26 THEN →CASE↓ GOTO 2 ;
      I := 0;
1:       IF NO ≠ 1 THEN
         BEGIN RECERR(11);
            IF TERRCL[NO] = BEGSY THEN GOTO 11;  GOTO 12;
         END;
         SRCHREC(NXT);
         IF CTPTR ≠ NIL THEN ERROR(5) ELSE
         BEGIN ALLOC(P,FIELD); I := I + 1;
            WITH P^ DO
            BEGIN NAME := AVAL;  NXTEL := NXT;  KLASS := FIELD;
               FLDTYPE := NIL;
            END;  NXT := P;
         END;
         INSYMBOL;
         IF NO = 15 THEN →,↓
         BEGIN INSYMBOL;  GOTO 1 END;
         IF NO ≠ 19 THEN →NOT :↓ ERROR(10) ELSE INSYMBOL;
11:      TYPEDECL(L,P);
         IF P ≠ NIL THEN
         IF P^.FORM > RECORDS THEN ERROR(30) ELSE
         BEGIN IF PACKFLAG THEN
            BEGIN IF I > 1 THEN →REVERSE POINTERS↓
               BEGIN PP := NXT;
                  FOR I := I DOWNTO 1 DO
                  BEGIN PP1 := PP^.NXTEL;
                    PP^.NXTEL := PP2;  PP2 := PP;
                    PP := PP1;
                  END;
                  NXT^.NXTEL := PP;  NXT := PP2;
               END →REVERSE↓ ELSE PP := NXT^.NXTEL;
               PP1 := NXT;
               IF P^.FORM ≤ POWER THEN
               BEGIN
                  CASE P^.FORM OF
   NUMERIC:         LL := P^.BITS;
   SYMBOLIC:        LL := P^.BITSIZE;
   POINTER:         LL := 18 ;
   POWER:           LL := P^.PWBITS;
                  END;
                  REPEAT
                     IF BDISPL + LL > WORDLENGTH THEN ADJUST;
                     IF LL = WORDLENGTH THEN
                     BEGIN PP1^.BITWIDTH := 0;
                       PP1^.FLDADDR := DISPL;  DISPL := DISPL + 1;
                     END ELSE
                     BEGIN PP1^.BITWIDTH := LL;
                       PP1^.BITDISPL := BDISPL;
                       PP1^.FLDADDR := DISPL;  BDISPL := BDISPL + LL;
                     END;
                     PP1^.FLDTYPE := P;
                     LASTFLD := PP1;  TAGFLAG := FALSE;
                     PP1 := PP1^.NXTEL;
                  UNTIL PP1 = PP;
               END →FORM <= POINTER↓ ELSE
               BEGIN IF BDISPL ≠ 0 THEN ADJUST;
                  TAGFLAG := FALSE;
                  REPEAT
                  PP1^.BITWIDTH := 0;  PP1^.FLDTYPE := P;
                     PP1^.FLDADDR := DISPL;
                     DISPL := DISPL + L;  LASTFLD := PP1;
                     PP1 := PP1^.NXTEL;
                  UNTIL PP1 = PP;
               END;
            END →PACKFLAG↓ ELSE
            BEGIN LL := DISPL + I*L;  DISPL := LL;
               PP := NXT;
               FOR I := I DOWNTO 1 DO
               BEGIN PP^.FLDTYPE := P;  LL := LL - L;
                  PP^.FLDADDR := LL;  PP^.BITWIDTH := 0;
                  PP := PP^.NXTEL;
               END;
            END;
         END →FORM <= RECORDS↓;
12:      IF NO = 16 THEN INSYMBOL;
   UNTIL (TERRCL[NO] = ENDSY) ∧ (NO ≠ 26);
   IF BDISPL ≠ 0 THEN ADJUST;
   MAXSIZE := DISPL;  VARPTR := NIL;
   GOTO 9;
2: →CASE↓
   INSYMBOL;
   IF NO ≠ 1 THEN ERROR(11) ELSE
   BEGIN SRCHREC(NXT);
      IF CTPTR ≠ NIL THEN ERROR(5) ELSE
      BEGIN ALLOC(P,FIELD);
         WITH P^ DO
         BEGIN NAME := AVAL;  NXTEL := NXT;  KLASS := FIELD;
            FLDTYPE := NIL;
         END;  NXT := P;
      END;
      INSYMBOL;
   END →NO = 1↓;
      IF NO ≠ 19 THEN ERROR(10) ELSE INSYMBOL;
      IF NO ≠ 1 THEN ERROR(11) ELSE
      BEGIN SRCHREC(NEXT);
         IF CTPTR = NIL THEN SEARCH;
         IF CTPTR = NIL THEN ERROR(12) ELSE
         IF (CTPTR^.KLASS≠TYPES) ∨ (CTPTR^.FORM>SYMBOLIC) THEN
            ERROR(7);
         INSYMBOL;
            IF NO ≠ 27 THEN ERROR(14);
            CPTR := CTPTR;
            IF CPTR ≠ NIL THEN
            IF PACKFLAG THEN
            BEGIN
                CASE CPTR^.FORM OF
   NUMERIC:         LL := CPTR^.BITS;
   SYMBOLIC:        LL := CPTR^.BITSIZE;
                END;
                IF BDISPL + LL > WORDLENGTH THEN ADJUST;
                P^.BITDISPL := BDISPL;  P^.BITWIDTH := LL;
                P^.FLDADDR := DISPL;  BDISPL := BDISPL + LL;
               LASTFLD := P;  CASEBITS := BDISPL;
            END →PACKFLAG↓ ELSE
            BEGIN P^.FLDADDR := DISPL;
               P^.BITWIDTH := 0;
            END;
            P^.FLDTYPE := CPTR;  DISPL := DISPL + 1;
            MINSIZE := DISPL;  MAXSIZE := DISPL;
            NXTC := NIL;  INSYMBOL;
            REPEAT  I := 0;
               REPEAT
                  IF (NO>2) ∨ (NO=2) ∧ ¬ (CL IN [1,4]) THEN
                  BEGIN RECERR(63);  GOTO 3 END ;
                  IF CPTR ≠ NIL THEN
                    IF NO = 1 THEN
                    BEGIN SRCHREC(NEXT);
                      IF CTPTR = NIL THEN SEARCH;
                      IF CTPTR = NIL THEN ERROR(12) ELSE
                      WITH CTPTR^ DO
                      IF KLASS ≠ KONST THEN ERROR(63) ELSE
                      IF (CPTR^.FORM = SYMBOLIC) ∧
                          (CONTYPE ≠ CPTR)  ∨
                        (CPTR^.FORM = NUMERIC) ∧
                          (CONTYPE ≠ INTPTR) THEN ERROR(73) ELSE
                      IT := VALUES;
                    END →NO = 1↓ ELSE
                    IF (CL = 1) ∧ (CPTR^.FORM ≠ NUMERIC)
                      ∨ (CL = 4) ∧ (CPTR ≠ CHARPTR) THEN
                      ERROR(73) ELSE
                    IT := IVAL;  →END CPTR <> NIL↓
                  ALLOC(P,TAGFIELD);
                  WITH P^ DO
                  BEGIN NAME := BLANK;  NXTEL := NXTC;
                    KLASS := TAGFIELD;
                    TAGVAL := TRUE;  CASEVAL := IT;
                  END;  NXTC := P;  I := I + 1;
                  INSYMBOL;
3:                IF NO ≠ 19 THEN ERROR(10) ELSE INSYMBOL;
               UNTIL NO > 2;
               IF NO = 9 THEN  → ( FIELDLIST ) ↓
               BEGIN IF PACKFLAG THEN
                  BEGIN DISPL := MINSIZE - 1;
                     BDISPL := CASEBITS;
                  END ELSE DISPL := MINSIZE;
                  INSYMBOL;  FIELDLIST(MXL,PP,NXT);
                  IF NO ≠ 10 THEN ERROR(9) ELSE INSYMBOL;
               END ELSE
               BEGIN PP := NIL;  MXL := MINSIZE END;
               P := NXTC;
               FOR I := I DOWNTO 1 DO
               WITH P^ DO
               BEGIN CASESIZE := MXL;  VARIANTS := PP;
                 P := NXTEL;
               END;  IF MAXSIZE < MXL THEN MAXSIZE := MXL;
               IF NO = 16 THEN INSYMBOL;
            UNTIL NO > 2;
            ALLOC(P,TAGFIELD);
            WITH P^ DO
            BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TAGFIELD;
               CASESIZE := MINSIZE;  VARIANTS := NXTC;
               TAGVAL := FALSE;  CASETYPE := CPTR;
            END;
            VARPTR := P;
      END →NO = 1↓;
9:    NXTF := NXT;
   END → FIELDLIST ↓;

→TYPEDECL↓
BEGIN PACKFLAG := FALSE;
   IF NO = 42 THEN →PACKED↓
   BEGIN PACKFLAG := TRUE;  INSYMBOL END;
   IF NO = 1 THEN
   BEGIN SRCHREC(NEXT);
      IF CTPTR = NIL THEN SEARCH;
      IF CTPTR = NIL THEN
      BEGIN ERROR(12);  P1 := NIL;  SKIPT(16) END ELSE
      BEGIN IF CTPTR^.KLASS = TYPES THEN →TYPE-ID↓
         BEGIN TL := CTPTR^.SIZE;  P1 := CTPTR;  INSYMBOL END ELSE
         IF CTPTR^.KLASS = KONST THEN SCALDECL(CTPTR) ELSE
         TYPERR(11);
      END;
   END →ID↓ ELSE
   IF NO = 9 THEN  → SYMBOLIC ↓
   BEGIN CV := 0;  LERR := ERR ;  ERR := FALSE;ALLOC(P,TYPES,SYMBOLIC);
      WITH P^ DO
      BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
         FORM := SYMBOLIC;
      END;  RTYP := P;  NXTC := NIL;
      REPEAT INSYMBOL;
         IF NO ≠ 1 THEN
         BEGIN ERROR(11);  SKIPT(15);
            GOTO 2;
         END;
         SRCHREC(NEXT);
            IF CTPTR ≠ NIL THEN ERROR(8) ELSE
            BEGIN ALLOC(P,KONST,ACTUAL);
               WITH P^ DO
               BEGIN NAME := AVAL;  NXTEL := NEXT;  KLASS := KONST;
                  CONTYPE := RTYP;  CONKIND := ACTUAL;
                  VALUES := CV;  SUCC := NXTC;
               END;  CV := CV + 1;  NEXT := P;  NXTC := P;
            END;
            INSYMBOL;
2:       UNTIL NO ≠ 15;
            ALLOC(P,TYPES,POWER) ;
            WITH P^ DO
            BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
               SIZE := 1;  FORM := POWER;
               ELSET := RTYP;  PWBITS := CV + 1;
            END;
            WITH RTYP^ DO
            BEGIN FCONST := NEXT;  SIZE := 1;
               BITSIZE := LOG2(CV - 1);  PWSET := P;
            END;
         IF ERR THEN P1 := NIL ELSE
         BEGIN ERR := LERR ;  P1 := RTYP END ;
         TL := 1 ;
         IF NO ≠ 10 THEN TYPERR(9) ELSE INSYMBOL ;
   END → SYMBOLIC ↓ ELSE
   IF NO IN [2,7] THEN → SUBRANGE ↓
   BEGIN LERR := ERR;  ERR := FALSE;
      SCALDECL(NEXT);
      IF ERR THEN ERROR(6) ELSE ERR := LERR
   END →SUBRANGE↓ ELSE
   IF NO = 38 THEN → STRUCTURED TYPES ↓
   CASE CL OF
→ARRAY↓ 1:
   BEGIN INSYMBOL;
      IF NO ≠ 11 THEN
      BEGIN TYPERR(98);
         IF TERRCL[NO] = BEGSY THEN TYPEDECL(I,CTPTR);  GOTO 19;
      END;
         NXTA := NIL;
         REPEAT ALLOC(P,TYPES,ARRAYS);
            WITH P^ DO
            BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
               FORM := ARRAYS;  AELTYPE := NXTA;
               → AELTYPE TEMPORARILY LINKS SUBARRAYS ↓
            END;  NXTA := P;
            INSYMBOL;
            LERR := ERR;  ERR := FALSE;
            SUBTYPE(I,J,P);
            IF ERR THEN
            BEGIN ERROR(6);  SKIPT(15);  I := 0;  J := 0;  P := NIL
            END ELSE
            ERR := LERR;
            WITH NXTA^ DO
            BEGIN LO := I;  HI := J;  INXTYPE := P END;
         UNTIL NO ≠ 15;
         IF NO ≠ 12 THEN
         BEGIN ERROR(37);  SKIPT(27);
            IF TERRCL[NO] = BEGSY THEN GOTO 11;
            IF NO = 27 THEN
            BEGIN INSYMBOL;  GOTO 11 END ;
            IF NO ≠ 12 THEN
            BEGIN P1 := NIL ;  TL := 0;  GOTO 19 END;
         END;
         INSYMBOL;
            IF NO ≠ 27 THEN ERROR(14) ELSE INSYMBOL;
11:         TYPEDECL(TL,CTPTR);
            IF CTPTR ≠ NIL THEN
            IF CTPTR^.FORM > RECORDS THEN
            BEGIN ERROR(30);  CTPTR := NIL END ELSE
            BEGIN
               REPEAT
                  WITH NXTA^ DO
                  BEGIN MULOPT(TL,E1,E2,OPT);
                     OPTTYP := OPT;  EXP1 := E1;  EXP2 := E2;
                     TL := TL*(HI - LO + 1);
                     SIZE := TL;
                     P := AELTYPE;  AELTYPE := CTPTR;
                  END;
                  CTPTR := NXTA;  NXTA := P;
               UNTIL NXTA = NIL;
               → NOW TL = SIZE OF ARRAY, CTPTR POINTS TO IT ↓
            END;  P1 := CTPTR;
19: END →ARRAY↓;
→RECORD↓ 2:
   BEGIN ALLOC(P,TYPES,RECORDS);
      WITH P^ DO
      BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
         FORM := RECORDS;
      END;  RTYP := P;
      INSYMBOL;  NXTF := NIL;
      DISPL := 0;  BDISPL := 0;  LERR := ERR;  ERR := FALSE;
      FIELDLIST(TL,P,NXTF);
      IF NO ≠ 22 THEN ERROR(17);
      IF ERR THEN TYPERR(18) ELSE
      WITH RTYP^ DO
      BEGIN SIZE := TL;  FSTFLD := NXTF;  RECVAR := P;
         P1 := RTYP;  ERR := LERR;
      END;
      IF NO = 22 THEN INSYMBOL;
   END →RECORD↓;
→FILE↓ 3:
   BEGIN INSYMBOL;
      IF NO = 27 THEN →OF↓
      BEGIN I := 8 ;  INSYMBOL END ELSE
      BEGIN INCONST(I,PT,NEXT) ;
         IF (I≤0) ∨ (PT≠INTPTR) THEN
         BEGIN ERROR(95) ;  I := 0 END ;
         IF NO ≠ 27 THEN ERROR(14) ELSE INSYMBOL ;
      END ;
      TYPEDECL(TL,CTPTR);
      IF CTPTR ≠ NIL THEN
      IF CTPTR^.FORM > RECORDS THEN
      BEGIN ERROR(30);  P1 := NIL END ELSE
      BEGIN L := CTPTR^.SIZE;
         LL := L DIV 64 + 1 ;
         IF LL < I THEN LL := I ;
         LL := ((LL*64) DIV L + 1) * L ;
         ALLOC(P,TYPES,FILES);
         WITH P^ DO
         BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
            FORM := FILES;  SIZE := LL;  FELTYPE := CTPTR;
         END;
         TL := LL;  P1 := P;
      END ELSE P1 := NIL;
   END →FILE↓;
→CLASS↓ 4:
   BEGIN ALLOC(P,TYPES,CLASSS);
      WITH P^ DO
      BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
         FORM := CLASSS;
      END;
      INSYMBOL ;
      IF NO = 27 THEN
      BEGIN I := 100 ;  INSYMBOL END ELSE
      BEGIN INCONST(I,PT,NEXT) ;
         IF (I≤0) ∨ (PT≠INTPTR) THEN
         BEGIN ERROR(6) ;  I := 0 END ;
         IF NO ≠ 27 THEN ERROR(14) ELSE INSYMBOL ;
      END ;
      TYPEDECL(TL,CTPTR);
      IF CTPTR ≠ NIL THEN
      IF CTPTR^.FORM > RECORDS THEN
      BEGIN ERROR(30);  P1 := NIL END ELSE
      BEGIN TL := TL*I + 1;
         P^.SIZE := TL;  P^.PELTYPE := CTPTR;
         P1 := P;
      END ELSE P1 := NIL ;
   END →CLASS↓;
→POWERSET↓ 5:
   BEGIN INSYMBOL;  LERR := ERR;  ERR := FALSE;
      SUBTYPE(I,J,P);
      IF ERR THEN TYPERR(6) ELSE
      BEGIN ERR := LERR;
         CASE P^.FORM OF
 NUMERIC:   IF (I < 0) ∨ (J > WORDLENGTH - 2) THEN
            BEGIN ERROR(6);  P1 := NIL END ELSE
               P1 := PNUMPTR;
 SYMBOLIC:  BEGIN IF P = CHARPTR THEN J := WORDLENGTH - 2  ;
               IF J > WORDLENGTH - 2 THEN
               BEGIN ERROR(6);  P1 := NIL END ELSE P1 := P^.PWSET;
            END;
         END →CASE↓;
         TL := 1;
      END →NOT ERR↓;
   END →POWERSET↓;

   END →STRUCTURED TYPES↓ ELSE
   IF NO = 18 THEN →POINTER↓
   BEGIN INSYMBOL;
      IF NO ≠ 1 THEN TYPERR(11) ELSE
      BEGIN TL := 1;  ALLOC(P,TYPES,POINTER);
         WITH P^ DO
         BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
            FORM := POINTER;  SIZE := 1;
         END;
         SRCHREC(NEXT);
         IF CTPTR = NIL THEN SEARCH;
         IF CTPTR ≠ NIL THEN
         IF CTPTR^.VTYPE = NIL THEN CTPTR := NIL;
         IF CTPTR = NIL THEN →UNDECLARED CLASS↓
         IF PTX > PTLIMIT THEN
         BEGIN ERROR(92);  P1 := NIL;  INSYMBOL END ELSE
         WITH PTLIST[PTX] , P^ DO
         BEGIN HNAME := AVAL;  PPTR := P;
            DOMAIN := P;  ELTYPE := P;
            PTX := PTX + 1;  P1 := P;  INSYMBOL;
         END ELSE
         WITH CTPTR^ DO
         IF (KLASS = VARS) ∧ (VTYPE^.FORM = CLASSS) THEN
         BEGIN P^.DOMAIN := CTPTR;
            P^.ELTYPE := VTYPE^.PELTYPE;
            P1 := P;  INSYMBOL;
         END ELSE TYPERR(15);
      END;
   END →POINTER↓ ELSE TYPERR(18);
END →TYPEDECL↓;

→ ------------------------------------------------------------ ↓

PROCEDURE BODY(SURRPTR,FIRSTENTRY:CTP);

LABEL 1;
VAR I,J : INTEGER;
   OLDLEV : RG3;
   LC1,TL,LL,VLC,FSTIX,LCA,LCP : SHRTINT ;
   N,P,PROCPTR,LFIRSTENTRY : CTP;
   TYPID : ALFA ; LCH : CWORD ;

   PROCEDURE FINDSEMICOLON;
   BEGIN IF NO ≠ 16 THEN
      BEGIN ERROR(58);  SKIP(16);
         IF NO ≠ 16 THEN GOTO EXIT 1;
      END;  INSYMBOL;
   END →FINDSEMICOLON↓;

PROCEDURE VARDECL;
   LABEL 10;
   VAR AT : ADDRESS; I,J : SHRTINT;

   PROCEDURE FILERR;
   BEGIN ERROR(95);  SKIP(12);  GOTO EXIT 10 END;

BEGIN INSYMBOL;
   WHILE NO = 1 DO
   BEGIN I := 0;
      REPEAT
         SRCHREC(NEXT);
         IF CTPTR ≠ NIL THEN ERROR(8) ELSE
         BEGIN ALLOC(P,VARS);
            WITH P^ DO
            BEGIN NAME := AVAL;  NXTEL := NEXT;  KLASS := VARS;
               VKIND := ACTUAL;  VTYPE := NIL;
               VLEVEL := 0 ;
            END;
            NEXT := P;  I := I + 1;
         END;
         INSYMBOL;
         IF NO = 11 THEN → [ IN,OUT,PRINT,PUNCH  ] ↓
         BEGIN INSYMBOL;
            IF (NO = 8) ∧ (CL = 7) THEN →IN↓
               P^.VLEVEL := 4  ELSE
            IF NO = 1 THEN
               IF AVAL = ≡OUT≡ THEN
                 P^.VLEVEL := 1  ELSE
               IF AVAL = ≡PRINT≡ THEN
                 P^.VLEVEL := 2 ELSE
               IF AVAL = ≡PUNCH≡ THEN
                 P^.VLEVEL := 3 ELSE FILERR ELSE FILERR ;
            INSYMBOL;  IF NO ≠ 12 THEN FILERR;
            INSYMBOL;
         END;
         ERR := FALSE;
         IF NO = 15 THEN
         BEGIN INSYMBOL;
            IF NO ≠ 1 THEN
            BEGIN ERROR(11);  GOTO 10 END;
         END ELSE IF NO ≠ 19 THEN ERROR(10);
      UNTIL NO ≠ 1 ;
      IF NO = 19 THEN INSYMBOL
         ELSE IF ¬ ERR THEN ERROR(10) ;
      N := NEXT;  ERR := FALSE;
      TYPEDECL(TL,CTPTR);
      IF ERR THEN GOTO 10;
      LC := LC + I*TL;  LL := LC;
      FOR I := I DOWNTO 1 DO
      WITH N^ DO
      BEGIN LL := LL - TL;
         VTYPE := CTPTR;
         IF CTPTR ≠ NIL THEN
         IF CTPTR^.FORM = CLASSS THEN
         BEGIN → CHECK FOR PREDECLARED CLASS ↓
            TYPID := NAME;  P := CTPTR^.PELTYPE;
            IF PFTOP = FILLIMIT THEN ERROR(92) ELSE
            BEGIN PFTOP := PFTOP + 1;  PFL[PFTOP] := LL END;
            FOR J := PTX - 1 DOWNTO 0 DO
            WITH PTLIST[J] DO
               IF HNAME = TYPID THEN
               BEGIN PPTR^.DOMAIN := N;
                  PPTR^.ELTYPE := P;
                  PTX := PTX - 1;
                  HNAME := PTLIST[PTX].HNAME;
                  PPTR := PTLIST[PTX].PPTR;
               END → WITH, FOR ↓ ;
            VLEVEL := LEVEL;  VADDR := LL;
         END → CHECK CLASS ↓ ELSE
         IF CTPTR^.FORM = FILES THEN
            IF FILTOP = FILLIMIT THEN ERROR(92) ELSE
            BEGIN FILTOP := FILTOP + 1;  FILPTS[FILTOP] := N;
               VADDR := LL;
               IF LEVEL > 0 THEN
               → TAKE EFET INTO ACCOUNT FOR ADDRESS ↓
               BEGIN IF CTPTR^.FELTYPE = CHARPTR THEN
                  J := ALFALENG + 7 ELSE J := 7;
                  LC := LC + J;  VADDR := VADDR + I*J - 7;
                  VLEVEL := LEVEL ;
               END;
            END →FORM = FILES↓ ELSE
         BEGIN VLEVEL := LEVEL;  VADDR := LL END;
         N := NXTEL;
      END → FOR I ↓ ;
10:   FINDSEMICOLON;
   END →WHILE NO = 1↓;
   IF NO = 47 THEN → VALUE ↓
      BEGIN IF LEVEL ≠ 0 THEN ERROR(22);
         INSYMBOL;
         WHILE NO = 1 DO
         BEGIN SRCHREC(NEXT);
            IF CTPTR = NIL THEN SEARCH;
            IF CTPTR = NIL THEN
            BEGIN ERROR(12);  FINDSEMICOLON;  GOTO 20 END;
            IF CTPTR^.KLASS ≠ VARS THEN
            BEGIN ERROR(26);  FINDSEMICOLON;  GOTO 20 END;
            WITH CTPTR^ DO
            BEGIN IT := VADDR;
               IF VLC = 0 THEN
               BEGIN VLC := IT;  LL := IT;  AT := IT;  END;
               IF IT < LL THEN ERROR(27) ELSE
               WHILE IT > AT DO
               BEGIN PUT(PASCLGO);  AT := AT + 1  END;
               INSYMBOL;
               IF (NO ≠ 8) ∨ (CL ≠ 6) THEN ERROR(4) ELSE INSYMBOL;
               IF NO = 9 THEN → LIST ↓
               BEGIN
                  REPEAT INSYMBOL;  INCONST(I,PT,NEXT);  IT1 := 1;
                     IF (NO = 6) ∧ (CL = 1) THEN → * ↓
                     BEGIN IT1 := I;  INSYMBOL;
                        INCONST(I,PT,NEXT);
                     END;
                     IF ¬ ERR THEN
                    BEGIN
                     FOR J := 1 TO IT1 DO
                     BEGIN PASCLGO^ := I;  PUT(PASCLGO)  END;
                     AT := AT + IT1;
                    END →NOT ERR↓;
                     IF ¬ (NO IN [15,10]) THEN → NOT , NOR ) ↓
                     BEGIN ERROR(20);  FINDSEMICOLON;  GOTO 20 END;
                  UNTIL NO = 10 ;  INSYMBOL;
               END ELSE
               BEGIN INCONST(I,PT,NEXT);
                  IF ¬ ERR THEN
                  BEGIN PASCLGO^ := I;  PUT(PASCLGO);
                     AT := AT + 1;
                  END;
               END;
               LL := IT + VTYPE^.SIZE;
               IF LL < AT THEN ERROR(20) ;
               FINDSEMICOLON;
            END →WITH↓;
20:         END →WHILE NO = 1↓;
            FOR AT := AT + 1 TO LC DO PUT(PASCLGO) ;
      END →VALUE↓ ELSE VLC := LC;
END →VARDECL↓ ;

PROCEDURE FORMPARM;
   → ( HAS BEEN VERIFIED AND NEXT SYMBOL READ ↓
   LABEL 3;
   VAR SPEC : IDCLASS;  REP : BOOLEAN;

   PROCEDURE FORMERR;
   BEGIN ERROR(11);  SKIP(10);  GOTO EXIT 3 END;

BEGIN SPEC := KONST ;
1: REPEAT
      IF NO = 45 THEN →PROCEDURE↓
      REPEAT INSYMBOL;
         IF NO ≠ 1 THEN ERROR(11) ELSE
         BEGIN SRCHREC(NEXT);
            IF CTPTR ≠ NIL THEN ERROR(8) ELSE
            BEGIN ALLOC(P,PROC);
               WITH P^ DO
               BEGIN NAME := AVAL;  NXTEL := NEXT;  KLASS := PROC;
                  PROCTYPE := P;  PROCKIND := FORMAL;
                  PROCADDR := LC;  PROCLEVEL := LEVEL;
                  FORMALS := NIL;
               END;  LC := LC + 1;  NEXT := P;
            END →CTPTR = NIL↓;
            INSYMBOL;
         END;
      UNTIL NO ≠ 15
      ELSE →NOT PROCEDURE↓
      BEGIN
         IF NO ≠ 1 THEN
         BEGIN IF NO = 43 THEN SPEC := VARS ELSE
            IF NO = 41 THEN SPEC := KONST ELSE
            IF NO = 44 THEN SPEC := PROC ELSE
               FORMERR;
            INSYMBOL;
         END ELSE IF SPEC ≠ VARS THEN SPEC := KONST ;
         IF NO ≠ 1 THEN FORMERR;
         REPEAT
            SRCHREC(NEXT);
            IF CTPTR ≠ NIL THEN ERROR(8) ELSE
            BEGIN
               CASE SPEC OF
   KONST:         BEGIN ALLOC(P,KONST,FORMAL);
                    WITH P^ DO
                    BEGIN CONTYPE := NIL;  CONKIND := FORMAL;
                      CADDR := LC;  CLEVEL := LEVEL;
                    END;
                  END;
   PROC:          BEGIN ALLOC(P,PROC);
                    WITH P^ DO
                    BEGIN PROCTYPE := NIL;  PROCKIND := FORMAL;
                      PROCADDR := LC;  PROCLEVEL := LEVEL;
                      FORMALS := NIL;
                    END;
                  END;
   VARS:          BEGIN ALLOC(P,VARS);
                    WITH P^ DO
                    BEGIN VTYPE := NIL;  VKIND := FORMAL;
                      VADDR := LC;  VLEVEL := LEVEL;
                    END;
                  END;
                  END →CASE↓;
                  P^.NAME := AVAL;  P^.NXTEL := NEXT;
                  P^.KLASS := SPEC;
                  LC := LC + 1;  NEXT := P;
               END →CTPTR = NIL↓;
               INSYMBOL;
               IF NO = 15 THEN
               BEGIN INSYMBOL;
                  IF NO = 19 THEN ERROR(11);
               END ELSE IF NO ≠ 19 THEN GOTO 4;
            UNTIL NO ≠ 1;
4:          IF NO ≠ 19 THEN ERROR(10) ELSE INSYMBOL;
            IF NO ≠ 1 THEN FORMERR;
            SEARCH;
            IF CTPTR = NIL THEN
            BEGIN ERROR(12);  GOTO 2 END;
            IF CTPTR^.KLASS ≠ TYPES THEN
            BEGIN ERROR(18) ;  GOTO 2 END ;
            N := NEXT;
            REPEAT
               CASE SPEC OF
   KONST:         IF N^.CONTYPE = NIL THEN
                  BEGIN IF ¬ (CTPTR^.FORM IN
                        [NUMERIC,SYMBOLIC,POWER]) THEN
                     BEGIN N^.KLASS := VARS;
                        IF CTPTR^.FORM = POINTER THEN
                           N^.VKIND := ACTUAL ;
                     END;
                     N^.CONTYPE := CTPTR;  N := N^.NXTEL;
                  END ELSE N := NIL;
   PROC:          IF N^.PROCTYPE = NIL THEN
                     IF CTPTR^.FORM > POWER THEN
                     BEGIN ERROR(93);  N := NIL END ELSE
                     BEGIN N^.PROCTYPE := CTPTR;  N := N^.NXTEL END
                  ELSE N := NIL;
   VARS:          IF N^.VTYPE = NIL THEN
                  BEGIN N^.VTYPE := CTPTR;  N := N^.NXTEL;
                  END ELSE N := NIL;
                  END →CASE↓;
               UNTIL N = NIL;
2:             INSYMBOL;
         END →NOT PROCEDURE↓;
3:       REP := NO IN [1,41,43,44,45];
         IF NO = 16 THEN
         BEGIN INSYMBOL;  REP := NO ≠ 10  END;
      UNTIL ¬ REP;
      IF NO ≠ 10 THEN
      BEGIN ERROR(9);  SKIP(10);
         IF NO IN [41,43,44,45] THEN GOTO 1;
      END;
      →REVERSE POINTERS↓
      N := NEXT;  NEXT := NIL;
      WHILE N ≠ NIL DO
      BEGIN P := N;  N := P^.NXTEL;
         P^.NXTEL := NEXT;  NEXT := P;
      END;
   END →FORMPARM↓;

   PROCEDURE OUTPMD(SURRPTR : CTP);
      CONST DIRECT = 0, INDIRECT = 1;
      VAR N,P : CTP;  ADR,ACC : SHRTINT;  OUT : BOOLEAN;
   BEGIN
      WITH PMDFILE^ DO
      BEGIN IF SURRPTR = NIL THEN
         BEGIN PNAME := ≡(MAIN)≡;  SA := IC END ELSE
         BEGIN PNAME := SURRPTR^.NAME;  SA := SURRPTR^.PROCADDR END;
         PKIND := PROCDR;  LINK := LASTLINK;  COUNT := 0;
      END;
      PUT(PMDFILE);  PMCTR := PMCTR + 2;  LASTLINK := PMCTR;
      N := NEXT;
      WHILE N ≠ NIL DO
      WITH N^ DO
      BEGIN OUT := FALSE;  ACC := DIRECT;
         CASE KLASS OF
 KONST:     IF CONKIND = FORMAL THEN
            BEGIN OUT := TRUE;  P := CONTYPE;  ADR := CADDR END;
 VARS:      BEGIN OUT := TRUE;  P := VTYPE;  ADR := VADDR;
               IF VKIND = FORMAL THEN ACC := INDIRECT;
            END;
TYPES,PROC:
         END;
         IF OUT THEN IF P^.FORM < POWER THEN
         BEGIN WITH PMDFILE^ DO
            BEGIN PNAME := NAME;  PKIND := OBJ;
               IF P^.FORM = NUMERIC THEN TYP := 1 ELSE
               IF P = REALPTR THEN TYP := 2 ELSE
               IF P = ALFAPTR THEN TYP := 3 ELSE
               IF P = CHARPTR THEN TYP := 4 ELSE
               IF P = BOOLPTR THEN TYP := 5 ELSE
               IF P^.FORM = SYMBOLIC THEN TYP := 1 ELSE TYP := 6 ;
               RLA := ADR;  ACCESS := ACC;
            END;
            PUT(PMDFILE);  PMCTR := PMCTR + 2;
         END;
         N := NXTEL;
      END →WITH, WHILE↓;
   END →OUTPMD↓;

   PROCEDURE ENTERBODY ;
   →GENERATES PROCEDURE PROLOG CODE AND PROCEDURE ENTRY CODE, CODE
    TO INITIALIZE EFETS AND TO OPEN LOCAL FILES, AND CODE TO INITIALIZE
    LOCAL CLASSPOINTERS↓
      CONST OPN = 104B ;
      VAR IT2 : SHRTINT;
   BEGIN CA := 0 ; CP := 4 ; LCX := 0 ;
      IF LEVEL ≠ 0 THEN
      BEGIN →PROCEDURE ENTRY CODE↓
         GEN15(76B,0,5,0) ; GEN15(20B,0,0,18) ;
         GEN15(12B,7,7,0) ; GEN15(66B,5,6,0) ;
         GEN30(51B,7,5,1) ; GEN30(61B,6,6,0) ;
         LCA := CA ; LCP := CP ;
         IF LEVEL ≠ 1 THEN GEN15(56B,6,5,0) ;
         →CODE TO INITIALIZE EFETS↓
         FOR IT := FILEV[LEVEL] TO FILTOP DO
         WITH FILPTS[IT]^ DO
         BEGIN
            UNPACK(NAME,LCH,1) ; IT2 := 7 ;
            WHILE LCH[IT2] = ≡ ≡ DO IT2 := IT2 - 1 ;
            RP := 0;  LDCST(INT(NAME));
            GEN15(43B,0,0,6*IT2);  GEN15(11B,6,0,1);
            GEN30(51B,6,5,VADDR+2);
            GEN30(71B,6,0,VTYPE^.FELTYPE^.SIZE);
            IF VTYPE^.FELTYPE ≠ CHARPTR THEN
            BEGIN GEN15(43B,0,0,1);
               GEN15(20B,0,0,56);  GEN15(12B,6,6,0);
            END;
            GEN30(51B,6,5,VADDR+1);
            GEN30(71B,6,5,VADDR+7);
            GEN30(51B,6,5,VADDR+3);
            GEN30(72B,6,6,VTYPE^.SIZE);
            GEN30(51B,6,5,VADDR+6);
         END;
      END ELSE
      BEGIN
         →MAIN PROGRAM, SAVE X7,B5 SET B6↓
         GEN15(56B,7,5,0) ; GEN15(76B,7,5,0) ;
         GEN30(51B,7,0,PARMLIST.ICO) ; GEN30(61B,6,5,0) ;
         LCA := CA ; LCP := CP ; LC := 1 ;
      END ;
      IF STOFLCHECK THEN GEN30(06B,6,4,STOFLERR) ;
      →CODE TO OPEN FILES↓
      IF LEVEL = 0 THEN IT2 := 0 ELSE IT2 := 5 ;
      FOR IT := FILEV[LEVEL] TO FILTOP DO
      BEGIN GEN30(61B,7,IT2,FILPTS[IT]^.VADDR+1);
         JUMPTO(OPN) ;
      END;
      →CODE TO INITIALIZE CLASSPOINTERS↓
      FOR IT := PILEV[LEVEL] TO PFTOP DO
      BEGIN IT1 := PFL[IT] ;
         GEN30(71B,7,IT2,IT1+1) ; GEN30(51B,7,IT2,IT1) ;
      END ;
      PFTOP := PILEV[LEVEL] - 1 ; TCT := 0 ; TMAX := 0 ; CLABIX := 0 ;
   END →ENTERBODY↓ ;

   PROCEDURE LEAVEBODY ;
   →CALLED AT PROCEDURE END. GOES THROUGH LABELTABLE LABTAB AND
     EXITTABLE EXTAB, UPDATING CODE, AND GENERATES PROCEDURE EXIT CODE↓
      CONST CLS = 105B ;
      VAR IT2,IT3 : INTEGER;
      PROCEDURE ERRMESSAGE(ALF:ALFA; VAL:SHRTINT) ;
      BEGIN ERROR(43) ; WRITE(EOL) ; PRTERR ;
         WRITE(≡ ≡,ALF:6,VAL:6,EOL) ;
         IF ¬ EOLFLAG THEN WRITE(≡ ≡:CHCNT+8)
      END →ERRMESSAGE↓ ;
   BEGIN IF LEVEL = 0 THEN IT2 := 0 ELSE IT2 := 5 ;
      FOR IT := FILEV[LEVEL] TO FILTOP DO
      BEGIN GEN30(61B,7,IT2,FILPTS[IT]^.VADDR + 1) ; JUMPTO(CLS) ;
      END ;
      FILTOP := FILEV[LEVEL] - 1 ;
      IF LEVEL ≠ 0 THEN →PROCEDURE EXIT CODE↓
      BEGIN GEN30(51B,1,5,1) ; GEN15(66B,6,5,0) ;
         GEN15(63B,7,1,0) ; GEN15(20B,1,0,42) ;
         GEN15(63B,5,1,0) ;
      END ELSE →MAIN, RETURN TO MONITOR↓
      BEGIN GEN15(56B,1,5,0) ; GEN15(63B,7,1,0) END ;
      GEN30(02B,7,0,0) ; LC := LC + TMAX ; INS(LC,LCP,LCA) ;
      FOR IT := 1 TO CLABIX DO
      WITH LABTAB[IT] DO
      BEGIN IF FLD2 > 0 THEN →UNDECLARED  LABEL↓
         BEGIN
            ERRMESSAGE(≡LABEL:≡,LABVAL) ;
            UNDLAB[FLD2].SUCC := CHNIX ; CHNIX := FLD3 ;
         END →IF FLD2 > 0↓ ;
      END →WITH, FOR↓ ;
      FOR IT := FSTIX TO CEXTABIX DO
      WITH EXTAB[IT] DO
      BEGIN FOR IT1 := 1 TO CLABIX DO
      WITH LABTAB[IT1] DO
      IF LABVAL = EXVAL THEN
      BEGIN IF FLD2 > 0 THEN ERRMESSAGE(≡EXIT:≡,EXVAL) ELSE
         BEGIN IT2 := JMPCST ; INSERT(LC,30,IT2) ;
            INSERT(FLD3,0,IT2) ; JMPTAB[JMPTABIX] := IT2
         END ;
         GOTO 2
      END →IF, WITH, FOR↓ ;
      ERRMESSAGE(≡EXIT:≡,EXVAL) ;
2:    END →WITH, FOR↓ ;
      CEXTABIX := FSTIX - 1 ;
      WRITOUT ;
      IF LEVEL = 0 THEN → WRITE OUT JUMPTABLE ↓
      FOR IT := 0 TO JMPMAX DO
      BEGIN PASCLGO^ := JMPTAB[IT] ; PUT(PASCLGO) END
   END →LEAVEBODY↓ ;

BEGIN →BODY↓
   PILEV[LEVEL]:= PFTOP+1;  VLC := 0;
   FILEV[LEVEL] := FILTOP + 1;
   FSTIX := CEXTABIX + 1 ;
1: IF NO = 40 THEN →LABEL↓
   BEGIN REPEAT INSYMBOL ;
         IF (NO = 2) ∧ (CL = 1) THEN
         BEGIN IF IVAL ≥ TWOTO17 THEN
            BEGIN ERROR(100) ; GOTO 2 END ;
            FOR IT := FSTIX TO CEXTABIX DO
            IF EXTAB[IT].EXVAL = IVAL THEN
            BEGIN ERROR(77) ; GOTO 2 END ;
            IF CEXTABIX = MAXEXLABS THEN ERROR(78) ELSE
            BEGIN CEXTABIX := CEXTABIX + 1 ;
               IF JMPIX > JMPMAX THEN ERROR(91) ELSE
               BEGIN WITH EXTAB[CEXTABIX] DO
                  BEGIN EXVAL := IVAL ; JMPTABIX := JMPIX END ;
                  JMPTAB[JMPIX] := LEVEL ; JMPIX := JMPIX + 1 ;
               END
            END ;
2:          INSYMBOL
         END →IF (NO=2) AND (CL=1)↓ ELSE
         BEGIN ERROR(61) ; GOTO 3 END
      UNTIL NO ≠ 15 →,↓ ;
3:    FINDSEMICOLON;
   END ;
   IF NO = 41 THEN → CONST ↓
   BEGIN INSYMBOL ;
         WHILE NO = 1 DO
         BEGIN REPEAT SRCHREC(NEXT) ; IF CTPTR ≠ NIL THEN ERROR(8);
         ALLOC(P,KONST,ACTUAL) ;
         WITH P^ DO
         BEGIN NAME := AVAL;  NXTEL := NEXT;  KLASS := KONST;
           CONKIND := ACTUAL;
         END;  NEXT := P;
         INSYMBOL;
         IF (NO ≠ 8) ∨ (CL ≠ 6) THEN ERROR(4) ELSE INSYMBOL;
         IF NO = 36 THEN → NIL ↓
         BEGIN P^.CONTYPE := NILPTR;
            P^.VALUES := NILVAL;  INSYMBOL;
         END ELSE
         BEGIN INCONST(I,N,NEXT^.NXTEL);
            P^.CONTYPE := N;  P^.VALUES := I;
         END;
            WHILE NO = 15 DO
            BEGIN INSYMBOL;
               IF NO ≠ 1 THEN
               BEGIN ERROR(11); SKIP(15) END;
            END;
         UNTIL NO ≠ 1;
         FINDSEMICOLON;
      END → WHILE NO = 1 ↓ ;
   END →CONST↓;
   IF NO =37 THEN →TYPE↓
   BEGIN INSYMBOL;
   WHILE NO = 1 DO
   BEGIN SRCHREC(NEXT); IF CTPTR ≠ NIL THEN ERROR(8);
      TYPID := AVAL;  INSYMBOL;
      IF (NO ≠ 8) ∨ (CL ≠ 6) THEN ERROR(4) ELSE INSYMBOL;
      ERR := FALSE;  TYPEDECL(TL,P);
      IF ¬ ERR THEN
      IF P^.NAME ≠ BLANK THEN ERROR(96) ELSE
      BEGIN P^.NAME := TYPID;  P^.NXTEL := NEXT;
         NEXT := P;
      END;
      FINDSEMICOLON;
   END;
   END →TYPE↓ ;
   IF NO=43 THEN →VAR↓
      VARDECL ELSE VLC := LC;
   IF PTX > 0 THEN
   BEGIN ERROR(12); WRITE(EOL); PRTERR;
      FOR PTX := PTX-1 DOWNTO 0 DO
         WRITE(≡ ≡,≡CLASS-ID≡,PTLIST[PTX].HNAME,EOL) ;
      IF ¬ EOLFLAG THEN WRITE(≡ ≡:CHCNT+8);
   END;
   IF LEVEL = 0 THEN
   BEGIN
      FOR I := 0 TO FILTOP DO
      WITH FILPTS[I]^ DO
      BEGIN
         IF VTYPE^.FELTYPE = CHARPTR THEN
         BEGIN IT := 0;  LC := LC + ALFALENG;
            FOR J := 1 TO ALFALENG DO PUT(PASCLGO);  →CHAR BUFFER↓
         END ELSE IT := 1;
         PUT(PASCLGO);  → P-PTR ↓
         J := 2*VLEVEL + IT;  →SPECIFIER↓  VLEVEL := 0;
         UNPACK(NAME,LCH,1) ; IT1 := 7 ;
         WHILE LCH[IT1] = ≡ ≡ DO IT1 := IT1 - 1 ;
         IT1 := (ALFALENG - IT1)*6 ;
         APPEND(J,55,VTYPE^.FELTYPE^.SIZE);
         PASCLGO^ := J;  PUT(PASCLGO);  → SPECIFIER + LRL ↓
         J := INT(NAME);  APPEND(J,-IT1,0);  APPEND(J,IT1,0);
         PASCLGO^ := J;  PUT(PASCLGO);  → LFN ↓
         PASCLGO^ := VADDR;
         FOR J := 1 TO 3 DO PUT(PASCLGO);  →FIRST,IN,OUT↓
         PASCLGO^ := VADDR + VTYPE^.SIZE;  PUT(PASCLGO);  → LIMIT ↓
         VADDR := LC;  LC := LC + 7;
      END;
      PARMLIST.LPJMPTAB := LC ;
      IF VLC ≠ LC THEN FOR J := 0 TO JMPMAX DO PUT(PASCLGO)
                   ELSE VLC := LC + (JMPMAX + 1) ;
      LC := LC + (JMPMAX + 1);
      IC := LC;  PARMLIST.LOADPT := VLC;  →LOADPT↓
   END;
   DP := FALSE;
   IF NO IN [44,45] THEN →FUNCTION OR PROCEDURE↓
   BEGIN IF SURRPTR ≠ NIL THEN
      IF SURRPTR^.PROCADDR = 0 THEN
      BEGIN IF JMPIX > JMPMAX THEN ERROR(91) ELSE
         BEGIN SURRPTR^.PROCADDR := PARMLIST.LPJMPTAB + JMPIX ;
            JMPIX := JMPIX + 1 ;
         END
      END;
   REPEAT
      LL := NO; ERR := FALSE;
      OLDLEV := LEVEL;
      IF LEVEL < MAXLEVEL THEN LEVEL := LEVEL + 1 ELSE ERROR(76);
      INSYMBOL;
      IF NO ≠ 1 THEN
      BEGIN ERROR(11);  LEVEL := OLDLEV;  GOTO 1 END;
      LC1 := LC;  SRCHREC(NEXT);
      IF CTPTR ≠ NIL THEN
      IF CTPTR^.KLASS ≠ PROC THEN
      BEGIN ERROR(8);  CTPTR := NIL END;
      IF CTPTR = NIL THEN → UNDECLARED PROCEDURE ↓
      BEGIN ALLOC(PROCPTR,PROC);
         WITH PROCPTR^ DO
         BEGIN NAME := AVAL;  NXTEL := NEXT;  KLASS := PROC;
            PROCTYPE := PROCPTR;  PROCKIND := ACTUAL;
            PROCLEVEL := LEVEL - 1;
         END;
         DISPLAY[TOP].FNAME := PROCPTR;
         NEXT := NIL ;
         INSYMBOL;
         IF LL = 44 THEN → FUNCTION ↓
         BEGIN IF NO ≠ 9 THEN ERROR(29) ELSE
            BEGIN LC := 3 ; INSYMBOL ; FORMPARM END ;
            IF ERR THEN PROCPTR^.PROCTYPE := NIL;
            IF NO = 10 THEN
            BEGIN INSYMBOL;
               IF NO ≠ 19 THEN ERROR(10) ELSE INSYMBOL;
               IF NO ≠ 1 THEN
               BEGIN ERROR(11);  SKIP(49);
                  PROCPTR^.PROCTYPE := NIL;
               END ELSE
               BEGIN SEARCH;
               IF CTPTR ≠ NIL THEN
               BEGIN IF CTPTR^.KLASS ≠ TYPES THEN
                  BEGIN ERROR(93);  CTPTR := NIL END ELSE
                  IF CTPTR^.FORM > POWER THEN
                  BEGIN ERROR(93) ;  CTPTR := NIL END ;
               END ELSE ERROR(12) ;
               PROCPTR^.PROCTYPE := CTPTR ;
               INSYMBOL;
                END;
            END →NO = 10↓;
         END → FUNCTION ↓  ELSE  → PROCEDURE ↓
         BEGIN LC := 3 ;
            IF NO = 9 THEN → PARMLIST ↓
            BEGIN INSYMBOL;  FORMPARM;
               IF ERR THEN PROCPTR^.PROCTYPE := NIL;
               IF NO = 10 THEN INSYMBOL;
            END →NO = 9↓;
         END →PROCEDURE↓;
         IF NO ≠ 16 THEN
         BEGIN PROCPTR^.PROCTYPE := NIL;
            ERROR(58);  SKIP(16);
         END ELSE INSYMBOL;
         PROCPTR^.FORMALS := NEXT;
         IF (NO=1) ∧ (AVAL=≡FORWARD≡) THEN
         BEGIN NEXT := PROCPTR;
            IF JMPIX > JMPMAX THEN ERROR(91) ELSE
               BEGIN PROCPTR^.PROCADDR :=
                  PARMLIST.LPJMPTAB + JMPIX ;
                  JMPIX := JMPIX + 1 ;
               END ;
            PROCPTR^.SEGSIZE := -LC;
            → SEGSIZE < 0 SIGNIFIES FORWARD-DECLARATION ↓
            INSYMBOL;
         END ELSE
         BEGIN TOP := LEVEL + 1;
            WITH DISPLAY[TOP] DO
            BEGIN FNAME := NEXT;  OCCUR := BLOCK  END;
            PROCPTR^.PROCADDR := 0;
            ALLOC(LFIRSTENTRY,DUMMYCLASS) ;
            BODY(PROCPTR,LFIRSTENTRY);
         END;
      END → NEW PROC ↓ ELSE → PROC ID ALREADY DECLARED ↓
      BEGIN
         IF CTPTR^.SEGSIZE ≥ 0 THEN → PREV. DECL NOT FORWARD ↓
            ERROR(16);
            INSYMBOL;
            IF NO = 9 THEN → IGNORE PARM-LIST ↓
            BEGIN ERROR(23);
               REPEAT SKIP(10);
                  IF NO IN [16,41,43,44,45] THEN INSYMBOL;
               UNTIL ¬ (NO IN [16,41,43,44,45]);
               IF NO ≠ 10 THEN ERROR(9) ELSE INSYMBOL;
            END;
            IF NO = 15 THEN SKIP(16);
            IF NO ≠ 16 THEN ERROR(58) ELSE INSYMBOL;
            IF (NO=1) ∧ (AVAL=≡FORWARD≡) THEN →AGAIN FORWARD↓
               INSYMBOL ELSE
            BEGIN
             PROCPTR := CTPTR;
             WITH PROCPTR^ DO
             BEGIN LC := -SEGSIZE;  NEXT := FORMALS  END;
             TOP := LEVEL + 1;
             WITH DISPLAY[TOP] DO
             BEGIN FNAME := NEXT;  OCCUR := BLOCK  END;
             ALLOC(LFIRSTENTRY,DUMMYCLASS);
             BODY(PROCPTR,LFIRSTENTRY);
            END →NOT FORWARD↓;
         END → OLD PROCEDURE ↓ ;
         LC := LC1;
         LEVEL := OLDLEV;
         FINDSEMICOLON;
      UNTIL ¬ (NO IN [44,45]) ;
   END → FUNCTION OR PROCEDURE ↓ ;
   DISPLAY[TOP].FNAME := NEXT;
   IF NO≠21 THEN
   BEGIN ERROR(24); SKIP(49);
      WHILE NO IN [16,22] DO
      BEGIN INSYMBOL;
         SKIP(49);
      END ;
      IF NO IN [37,40,41,43,44,45] THEN GOTO 1;
   END ELSE
   IF SURRPTR = NIL THEN PARMLIST.ENTRYPT := IC ELSE
   WITH SURRPTR^ DO
   BEGIN IF PROCADDR ≠ 0 THEN
      BEGIN I := IC ; APPEND(I,30,EQJMP) ;
         JMPTAB[PROCADDR - PARMLIST.LPJMPTAB] := I
      END ;
      PROCADDR := IC
   END ;
   N := NEXT ; ERR := FALSE ;
   WHILE N ≠ NIL DO
      IF N^.KLASS ≠ PROC THEN N := NIL ELSE
      BEGIN IF N^.SEGSIZE < 0 THEN →FORWARD, NO REAL DECLARATION↓
         BEGIN IF ¬ ERR THEN
            BEGIN ERROR(12) ; WRITE(EOL) ; PRTERR END ;
            WRITE(≡ PROCEDURE≡,≡ ≡:2,N^.NAME,EOL) ;
         END ;
         N := N^.NXTEL ;
      END →IF, WHILE↓ ;
   IF ERR THEN IF ¬ EOLFLAG THEN WRITE(≡ ≡:CHCNT+8) ;
   IF PARMLIST.ERRFLAG = FALSE THEN OUTPMD(SURRPTR) ;
   ENTERBODY;
   COMPSTAT ;
   LEAVEBODY ;
   IF SURRPTR ≠ NIL THEN SURRPTR^.SEGSIZE := LC;
   ALLOC(P,DUMMYCLASS);
   IF P > MAXCTP THEN MAXCTP := P;
   RESET(FIRSTENTRY);
   TOP := LEVEL;  NEXT := DISPLAY[TOP].FNAME;
END → BODY ↓ ;

→ ------------------------------------------------------------ ↓
→ M A I N   P R O G R A M ↓

BEGIN

   → INITIALIZE CONTEXT-TABLE ↓
   ALLOC(NILPTR,TYPES,POINTER);   →TYPE OF NIL↓
   WITH NILPTR^ DO
   BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
      SIZE := 0;  FORM := POINTER;  DOMAIN := NIL;  ELTYPE := NIL;
   END;
   NEXT := NIL ;
   FOR IT := 0 TO 11 DO   →TEXT, WEOR, GET, PUT, RESET, ALLOC↓
   BEGIN ALLOC(PT,PROC);   →PACK, UNPACK, INSERT, APPEND, READ, WRITE↓
      WITH PT^ DO
      BEGIN NAME := INITNAM[IT-1];  NXTEL := NEXT;  KLASS := PROC;
         PROCTYPE := PT;  FORMALS := NIL;
         PROCADDR := 0 ;  PROCLEVEL := 0 ;  SEGSIZE := IT ;
         PROCKIND := ACTUAL;
      END;  NEXT := PT;
   END;
   FOR IT := 1 TO 9 DO
   BEGIN ALLOC(PT,PROC);   →ODD, INT, CHR, EOF, ABS, SQR, TRUNC,↓
      WITH PT^ DO          →PRED, SUCC↓
      BEGIN NAME := INITNAM[IT+10];  NXTEL := NEXT;  KLASS := PROC;
         PROCTYPE := NILPTR;  FORMALS := NIL;
         PROCADDR := 0 ;  PROCLEVEL := 0 ;  SEGSIZE := IT ;
         PROCKIND := ACTUAL;
      END;  NEXT := PT;
   END;
   ALLOC(CTPTR,TYPES,FILES);   →TYPE OF INPUT AND OUTPUT↓
   WITH CTPTR^ DO
   BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
      SIZE := 513;  FORM := FILES;
   END;  FILPTS[1] := CTPTR;
   FOR IT := 22 TO 23 DO
   BEGIN ALLOC(PT,VARS);   →INPUT, OUTPUT↓
      WITH PT^ DO
      BEGIN NAME := INITNAM[IT];  NXTEL := NEXT;  KLASS := VARS;
         VTYPE := CTPTR;  VKIND := ACTUAL;
         IF IT = 22 THEN
            VADDR := INPT ELSE VADDR := OUTPT ;
         VLEVEL := 0;
      END;  NEXT := PT;
   END;
   ALLOC(ALFAPTR,TYPES,SYMBOLIC);   →ALFA↓
   WITH ALFAPTR^ DO
   BEGIN NAME := INITNAM[24];  NXTEL := NEXT;  KLASS := TYPES;
      SIZE := 1;  FORM := SYMBOLIC;  FCONST := NIL;  PWSET := NIL;
      BITSIZE := WORDLENGTH;
   END;
   ALLOC(REALPTR,TYPES,SYMBOLIC);   →REAL↓
   WITH REALPTR^ DO
   BEGIN NAME := INITNAM[25];  NXTEL := ALFAPTR;  KLASS := TYPES;
      SIZE := 1;  FORM := SYMBOLIC;  FCONST := NIL;  PWSET := NIL;
      BITSIZE := WORDLENGTH;
   END;
   ALLOC(CHARPTR,TYPES,SYMBOLIC);   →CHAR↓
   WITH CHARPTR^ DO
   BEGIN NAME := INITNAM[26];  NXTEL := REALPTR;  KLASS := TYPES;
      SIZE := 1;  FORM := SYMBOLIC;  BITSIZE := 7;
   END;
   ALLOC(PT,KONST,ACTUAL);   →' '↓
   WITH PT^ DO
   BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := KONST;
      CONTYPE := CHARPTR;  CONKIND := ACTUAL;
      VALUES := 63;  SUCC := NIL;
   END;  CHARPTR^.FCONST := PT;
   ALLOC(BOOLPTR,TYPES,SYMBOLIC);   →BOOLEAN↓
   WITH BOOLPTR^ DO
   BEGIN NAME := INITNAM[27];  NXTEL := CHARPTR;  KLASS := TYPES;
      SIZE := 1;  FORM := SYMBOLIC;  BITSIZE := 2;
   END;
   ALLOC(PT,KONST,ACTUAL);   →EOL↓
   WITH PT^ DO
   BEGIN NAME := INITNAM[20]; NXTEL := BOOLPTR;
      KLASS := KONST; CONTYPE := CHARPTR; CONKIND := ACTUAL;
      VALUES := 0; SUCC := NIL
   END ;
   NEXT := PT; CTPTR := NIL;
   FOR IT := 0 TO 1 DO
   BEGIN ALLOC(PT,KONST,ACTUAL);   →FALSE, TRUE↓
      WITH PT^ DO
      BEGIN NAME := INITNAM[IT+28];  NXTEL := NEXT;
         KLASS := KONST;  CONTYPE := BOOLPTR;  CONKIND := ACTUAL;
         VALUES := IT;  SUCC := CTPTR;
      END;  CTPTR := PT;  NEXT := PT;
   END;
   BOOLPTR^.FCONST := NEXT;
   ALLOC(INTPTR,TYPES,NUMERIC);   →INTEGER↓
   WITH INTPTR^ DO
   BEGIN NAME := INITNAM[30];  NXTEL := NEXT;  KLASS := TYPES;
      SIZE := 1 ;  FORM := NUMERIC ;
      MIN := 77774000000000000000B;  MAX := 3777777777777777B;
      BITS := WORDLENGTH;
   END;  PREDEFP := INTPTR;
   FOR IT := 1 TO 2 DO
   BEGIN ALLOC(PT,TYPES,POWER);   →POWERSET CHAR, POWERSET BOOLEAN↓
      WITH PT^ DO
      BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
         SIZE := 1;  FORM := POWER;
         IF IT = 1 THEN →POWERSET BOOLEAN↓
         BEGIN ELSET := BOOLPTR;  BOOLPTR^.PWSET := PT;  PWBITS := 3;
         END ELSE →POWERSET CHAR↓
         BEGIN ELSET := CHARPTR;  CHARPTR^.PWSET := PT;
            PWBITS := WORDLENGTH;
         END;
      END;
   END;
   ALLOC(UNDECPTR,VARS);   →TYPE OF ALL UNDECLARED IDES↓
   WITH UNDECPTR^ DO
   BEGIN NAME := BLANK ; NXTEL := NIL ; KLASS := VARS ; VTYPE := NIL ;
      VKIND := ACTUAL ; VADDR := 0 ; VLEVEL := 0 ;
   END ;
   ALLOC(PNUMPTR,TYPES,POWER);   →TYPE OF POWERSET 0..58↓
   WITH PNUMPTR^ DO
   BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
      SIZE := 1;  FORM := POWER;  ELSET := INTPTR;  PWBITS := WORDLENGTH;
   END;
   ALLOC(LAMPTR,TYPES,POWER);   →TYPE OF [ ]↓
   WITH LAMPTR^ DO
   BEGIN NAME := BLANK;  NXTEL := NIL;  KLASS := TYPES;
      SIZE := 1;  FORM := POWER;  ELSET := NIL;  PWBITS := 0;
   END;
   ALLOC(CTPTR,KONST,FORMAL);   →TYPE OF PARAM OF EXTERNAL PROCEDURES↓
   WITH CTPTR^ DO
   BEGIN NAME := BLANK ; NXTEL := NIL ; KLASS := KONST ;
      CONTYPE := REALPTR ; CONKIND := FORMAL ;
      CADDR := 3 ; CLEVEL := 0 ;
   END ;
   NEXT := INTPTR ;
   ALLOC(PT,KONST,ACTUAL);   →ALFALENG↓
   WITH PT^ DO
   BEGIN NAME := INITNAM[21] ; NXTEL := NEXT ; KLASS := KONST ;
      CONTYPE := INTPTR ; CONKIND := ACTUAL ; VALUES := 10 ;
      SUCC := NIL
   END ;
   NEXT := PT ;
   FOR IT := 32 TO 37 DO
   BEGIN ALLOC(PT,PROC);   →SIN, COS, EXP, LN, SQRT, ARCTAN↓
      WITH PT^ DO
      BEGIN NAME := INITNAM[IT] ; NXTEL := NEXT ;
         KLASS := PROC ; PROCTYPE := REALPTR ;
         PROCKIND := ACTUAL ; PROCLEVEL := 0 ;
         FORMALS := CTPTR; PROCADDR := IT + 58;
         IF IT ≤ 33 THEN SEGSIZE := 0 ELSE SEGSIZE := IT - 33 ;
      END ;
      NEXT := PT
   END ;
   EXTPTR := NEXT ;
   FILPTS[1]^.FELTYPE := CHARPTR;

   DIGITS := [≡0≡,≡1≡,≡2≡,≡3≡,≡4≡,≡5≡,≡6≡,≡7≡,≡8≡,≡9≡];
   FOR IT := 0 TO 3 DO PARMLIST.ERRNRS[IT] := [ ] ;
   ERRINX := 0;  EOLFLAG := TRUE;
   PARMLIST.ERRFLAG := FALSE ;
   DP := TRUE;  PRCODE := FALSE;
   PMCTR := 0;  LASTLINK := 0;  →FOR PMDFILE↓
   ASSCHECK := TRUE ; INXCHECK := TRUE ; DIVCHECK := TRUE ;
   STOFLCHECK := TRUE ; ROUNDING := TRUE ;
   KK := ALFALENG;  FILTOP := -1;  JMPIX := 0;  CEXTABIX := 0;
   PTX := 0;  CHNIX := 1;  B6DPL := 3;
   FOR IT := 1 TO UNDMAX-1 DO UNDLAB[IT].SUCC := IT + 1 ;
   UNDLAB[UNDMAX].SUCC := 0 ;
   IC := PARMLIST.ICO + 1 ;
   MAXCTP := LAMPTR;
   PARMLIST.EXTFLAGS := [ ] ;
   WITH DISPLAY[0] DO
   BEGIN FNAME := EXTPTR ; OCCUR := BLOCK END ;
   NO := 0 ; LC := IC;
   NEXTCH;  INSYMBOL;
   REPEAT
      DISPLAY[1].FNAME := NIL;  DISPLAY[1].OCCUR := BLOCK;
      TOP := 1;  LEVEL := 0;  NEXT := NIL;
      ALLOC(PT,DUMMYCLASS);  LC := IC ;  PFTOP := -1;

      →********************
       *                   ↓
      BODY(NIL,PT);  →  COMPILE USER PROGRAM
       *                   *
       ********************↓

      IF (LEVEL = 0) ∧ (NO ≠ 17) THEN ERROR(54) ;
   UNTIL NO = 17 → . ↓ ;
   WHILE ¬ EOLFLAG DO NEXTCH;  IF ERRINX > 0 THEN PRTERR;
   IF PRCODE THEN PRJMPTAB;
   PMDFILE^.PKIND := PROCDR;  PMDFILE^.COUNT := LASTLINK;
   PUT(PMDFILE);  →LINK TO MAIN PROGRAM ENTRY↓
   WRITE(EOL) ;
   PARMLIST.LIMCODE := IC ;
END .
