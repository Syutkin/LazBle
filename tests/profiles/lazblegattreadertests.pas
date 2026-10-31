unit LazBleGattReaderTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, LazBleGattReader;

type
  TLazBleGattReaderTest = class(TTestCase)
  published
    procedure ReadsConsecutiveLittleEndianIntegers;
    procedure SupportsFullUnsigned32BitRange;
    procedure ReadsWideLittleEndianIntegers;
    procedure SupportsFullUnsigned64BitRange;
    procedure SignedIntegersPreserveAllWidthBoundaries;
    procedure RejectsInvalidWidthsAndShortBuffers;
    procedure InvalidWidthsFailWithEnoughData;
    procedure TruncatedIntegersDoNotConsumePartialFields;
    procedure FailedReaderStaysFailedUntilRecreated;
    procedure SFloatPreservesSignsDecimalScaleAndZero;
    procedure SFloatPreservesSpecialValues;
    procedure ReservedAndTruncatedSFloatFail;
    procedure UnsignedValueIsAbsentAfterFailedRead;
    procedure UnsignedValuePreservesExactlyRepresentableWideIntegers;
    procedure UnsignedValueRejectsPrecisionLoss;
    procedure Utf8ReadsRemainingBytesAfterBinaryPrefix;
    procedure Utf8AcceptsEmptyAndUnicodeBoundaries;
    procedure Utf8RejectsMalformedSequencesWithoutAdvancing;
    procedure FinishedRequiresExactConsumption;
  end;

implementation

procedure TLazBleGattReaderTest.ReadsConsecutiveLittleEndianIntegers;
var
  Reader: TBleGattReader;
begin
  Reader := TBleGattReader.Create(TBytes.Create($12, $34, $56, $78, $9A,
    $BC, $DE, $F0, $12, $34));
  AssertEquals(QWord($12), Reader.UInt(1));
  AssertEquals(QWord($5634), Reader.UInt(2));
  AssertEquals(QWord($BC9A78), Reader.UInt(3));
  AssertEquals(QWord($3412F0DE), Reader.UInt(4));
  AssertEquals(10, Reader.Position);
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.SupportsFullUnsigned32BitRange;
var
  Reader: TBleGattReader;
begin
  Reader := TBleGattReader.Create(TBytes.Create($FF, $FF, $FF, $FF));
  AssertEquals(QWord($FFFFFFFF), QWord(Reader.UInt(4)));
  AssertTrue(Reader.Valid);
end;

procedure TLazBleGattReaderTest.SignedIntegersPreserveAllWidthBoundaries;
var
  Reader: TBleGattReader;
  Value: TBytes;
  Width, I: Integer;
  Minimum, Maximum: Int64;
begin
  for Width := 1 to 8 do
  begin
    if Width = 8 then
    begin
      Minimum := Low(Int64);
      Maximum := High(Int64);
    end
    else
    begin
      Minimum := -(Int64(1) shl (Width * 8 - 1));
      Maximum := (Int64(1) shl (Width * 8 - 1)) - 1;
    end;
    Value := nil;
    SetLength(Value, Width);
    Value[Width - 1] := $80;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Minimum, Int64(Reader.SInt(Width)));
    for I := 0 to Width - 1 do Value[I] := $FF;
    Value[Width - 1] := $7F;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Maximum, Int64(Reader.SInt(Width)));
    Value[Width - 1] := $FF;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Int64(-1), Reader.SInt(Width));
    AssertTrue(Reader.Finished);
  end;
end;

procedure TLazBleGattReaderTest.RejectsInvalidWidthsAndShortBuffers;
var
  Reader: TBleGattReader;
  Width: Integer;
begin
  for Width := -1 to 9 do
  begin
    Reader := TBleGattReader.Create(TBytes.Create(1));
    if Width = 1 then Continue;
    AssertEquals(QWord(0), Reader.UInt(Width));
    AssertFalse(Reader.Valid);
    AssertEquals(0, Reader.Position);
  end;
end;

procedure TLazBleGattReaderTest.ReadsWideLittleEndianIntegers;
const
  Expected: array[5..8] of QWord = (
    $5544332211, $665544332211, $77665544332211, QWord($8877665544332211));
var
  Reader: TBleGattReader;
  Value: TBytes;
  Width: Integer;
begin
  for Width := 5 to 8 do
  begin
    Value := TBytes.Create($11, $22, $33, $44, $55, $66, $77, $88);
    SetLength(Value, Width);
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Expected[Width], QWord(Reader.UInt(Width)));
    AssertTrue(Reader.Finished);
  end;
  Reader := TBleGattReader.Create(TBytes.Create($11, $22, $33, $44,
    $55, $66, $77, $88, $42));
  AssertEquals(Expected[8], QWord(Reader.UInt(8)));
  AssertEquals(QWord($42), Reader.UInt(1));
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.SupportsFullUnsigned64BitRange;
var
  Reader: TBleGattReader;
  Value: TBytes;
  Expected: QWord;
  Width, I: Integer;
begin
  for Width := 1 to 8 do
  begin
    Value := nil;
    SetLength(Value, Width);
    Reader := TBleGattReader.Create(Value);
    AssertEquals(QWord(0), QWord(Reader.UInt(Width)));
    AssertTrue(Reader.Finished);
    for I := 0 to Width - 1 do Value[I] := $FF;
    if Width = 8 then Expected := High(QWord)
    else Expected := (QWord(1) shl (Width * 8)) - 1;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Expected, QWord(Reader.UInt(Width)));
    AssertTrue(Reader.Finished);
  end;
end;

procedure TLazBleGattReaderTest.InvalidWidthsFailWithEnoughData;
const
  InvalidWidths: array[0..3] of Integer = (-1, 0, 9, 16);
var
  Reader: TBleGattReader;
  Value: TBytes;
  Width: Integer;
begin
  SetLength(Value, 16);
  for Width in InvalidWidths do
  begin
    Reader := TBleGattReader.Create(Value);
    AssertEquals(QWord(0), QWord(Reader.UInt(Width)));
    AssertFalse(Reader.Valid);
    AssertEquals(0, Reader.Position);
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Int64(0), Int64(Reader.SInt(Width)));
    AssertFalse(Reader.Valid);
    AssertEquals(0, Reader.Position);
  end;
end;

procedure TLazBleGattReaderTest.TruncatedIntegersDoNotConsumePartialFields;
var
  Reader: TBleGattReader;
  Value: TBytes;
  Width: Integer;
begin
  for Width := 1 to 8 do
  begin
    SetLength(Value, Width);
    Value[0] := $42;
    Reader := TBleGattReader.Create(Value);
    Reader.UInt(1);
    AssertEquals(QWord(0), QWord(Reader.UInt(Width)));
    AssertFalse(Reader.Valid);
    AssertEquals(1, Reader.Position);
    Reader := TBleGattReader.Create(Value);
    Reader.UInt(1);
    AssertEquals(Int64(0), Int64(Reader.SInt(Width)));
    AssertFalse(Reader.Valid);
    AssertEquals(1, Reader.Position);
  end;
end;

procedure TLazBleGattReaderTest.UnsignedValuePreservesExactlyRepresentableWideIntegers;
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
  Value: TBytes;
  Expected: Double;
  I: Integer;
begin
  for I := 0 to 5 do
  begin
    case I of
      0:
        begin
          Value := TBytes.Create($FF, $FF, $FF, $FF, $FF, $FF);
          Expected := 281474976710655.0;
        end;
      1:
        begin
          Value := TBytes.Create($FF, $FF, $FF, $FF, $FF, $FF, $1F);
          Expected := 9007199254740991.0;
        end;
      2:
        begin
          Value := TBytes.Create(0, 0, 0, 0, 0, 0, $20);
          Expected := 9007199254740992.0;
        end;
      3:
        begin
          Value := TBytes.Create(2, 0, 0, 0, 0, 0, $20);
          Expected := 9007199254740994.0;
        end;
      4:
        begin
          Value := TBytes.Create(0, 0, 0, 0, 0, 0, 0, $80);
          Expected := 9223372036854775808.0;
        end;
      5:
        begin
          Value := TBytes.Create(0, $F8, $FF, $FF, $FF, $FF, $FF, $FF);
          Expected := 18446744073709549568.0;
        end;
    end;
    Reader := TBleGattReader.Create(Value);
    Number := Reader.UIntValue(Length(Value));
    AssertEquals(Ord(lgvsFinite), Ord(Number.State));
    AssertEquals(Expected, Number.Value, 0.0);
    AssertTrue(Reader.Finished);
  end;
end;

procedure TLazBleGattReaderTest.UnsignedValueRejectsPrecisionLoss;
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
  Value: TBytes;
  Expected: QWord;
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    case I of
      0:
        begin
          Value := TBytes.Create(1, 0, 0, 0, 0, 0, $20);
          Expected := $20000000000001;
        end;
      1:
        begin
          Value := TBytes.Create(2, 0, 0, 0, 0, 0, $40);
          Expected := $40000000000002;
        end;
      2:
        begin
          Value := TBytes.Create($FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF);
          Expected := High(QWord);
        end;
    end;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(Expected, QWord(Reader.UInt(Length(Value))));
    AssertTrue(Reader.Finished);
    Reader := TBleGattReader.Create(Value);
    Number := Reader.UIntValue(Length(Value));
    AssertEquals(Ord(lgvsAbsent), Ord(Number.State));
    AssertFalse(Reader.Valid);
  end;
end;

procedure TLazBleGattReaderTest.FailedReaderStaysFailedUntilRecreated;
var
  Reader: TBleGattReader;
begin
  Reader := TBleGattReader.Create(TBytes.Create(42));
  Reader.UInt(2);
  AssertEquals(QWord(0), Reader.UInt(1));
  AssertFalse(Reader.Valid);
  AssertFalse(Reader.Finished);
  Reader := TBleGattReader.Create(TBytes.Create(42));
  AssertEquals(QWord(42), Reader.UInt(1));
  Reader.Invalidate;
  AssertFalse(Reader.Finished);
end;

procedure TLazBleGattReaderTest.SFloatPreservesSignsDecimalScaleAndZero;
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
begin
  Reader := TBleGattReader.Create(TBytes.Create($7D, $F0, $85, $FF,
    0, 0, $7D, $E0, 2, $10));
  Number := Reader.SFloat;
  AssertEquals(Ord(lgvsFinite), Ord(Number.State));
  AssertEquals(12.5, Number.Value, 0.000001);
  Number := Reader.SFloat;
  AssertEquals(-12.3, Number.Value, 0.000001);
  Number := Reader.SFloat;
  AssertEquals(Ord(lgvsFinite), Ord(Number.State));
  AssertEquals(0.0, Number.Value);
  Number := Reader.SFloat;
  AssertEquals(1.25, Number.Value, 0.000001);
  Number := Reader.SFloat;
  AssertEquals(20.0, Number.Value);
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.SFloatPreservesSpecialValues;
const
  Expected: array[0..3] of TBleGattValueState = (
    lgvsPositiveInfinity, lgvsNegativeInfinity, lgvsNaN, lgvsNotAtResolution);
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
  I: Integer;
begin
  Reader := TBleGattReader.Create(TBytes.Create($FE, 7, 2, 8, $FF, 7, 0, 8));
  for I := 0 to High(Expected) do
  begin
    Number := Reader.SFloat;
    AssertEquals(Ord(Expected[I]), Ord(Number.State));
    AssertEquals(0.0, Number.Value);
  end;
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.ReservedAndTruncatedSFloatFail;
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
begin
  Reader := TBleGattReader.Create(TBytes.Create(1, 8));
  Number := Reader.SFloat;
  AssertFalse(Reader.Valid);
  AssertEquals(Ord(lgvsAbsent), Ord(Number.State));
  Reader := TBleGattReader.Create(TBytes.Create($FF));
  Number := Reader.SFloat;
  AssertFalse(Reader.Valid);
  AssertEquals(Ord(lgvsAbsent), Ord(Number.State));
end;

procedure TLazBleGattReaderTest.UnsignedValueIsAbsentAfterFailedRead;
var
  Reader: TBleGattReader;
  Number: TBleGattValue;
begin
  Reader := TBleGattReader.Create(TBytes.Create(0));
  Number := Reader.UIntValue(1);
  AssertEquals(Ord(lgvsFinite), Ord(Number.State));
  AssertEquals(0.0, Number.Value);
  Number := Reader.UIntValue(1);
  AssertEquals(Ord(lgvsAbsent), Ord(Number.State));
  AssertFalse(Reader.Valid);
end;

procedure TLazBleGattReaderTest.Utf8ReadsRemainingBytesAfterBinaryPrefix;
var
  Reader: TBleGattReader;
  Text: UTF8String;
begin
  Reader := TBleGattReader.Create(TBytes.Create($FF, $41, $C3, $A9));
  AssertEquals(QWord($FF), Reader.UInt(1));
  Text := Reader.Utf8Text;
  AssertEquals(3, Length(Text));
  AssertEquals($C3, Ord(Text[2]));
  AssertEquals($E9, Ord(UTF8Decode(Text)[2]));
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.Utf8AcceptsEmptyAndUnicodeBoundaries;
var
  Reader: TBleGattReader;
  Text: UTF8String;
begin
  Reader := TBleGattReader.Create(nil);
  AssertEquals('', Reader.Utf8Text);
  AssertTrue(Reader.Finished);
  Reader := TBleGattReader.Create(TBytes.Create($7F, $C2, $80, $DF, $BF,
    $E0, $A0, $80, $ED, $9F, $BF, $EE, $80, $80, $EF, $BF, $BF,
    $F0, $90, $80, $80, $F4, $8F, $BF, $BF));
  Text := Reader.Utf8Text;
  AssertEquals(25, Length(Text));
  AssertTrue(Reader.Finished);
end;

procedure TLazBleGattReaderTest.Utf8RejectsMalformedSequencesWithoutAdvancing;
var
  Reader: TBleGattReader;
  Value: TBytes;
  I: Integer;
begin
  for I := 0 to 5 do
  begin
    case I of
      0: Value := TBytes.Create(1, $ED, $A0, $80);
      1: Value := TBytes.Create(1, $F4, $90, $80, $80);
      2: Value := TBytes.Create(1, $E2, $82);
      3: Value := TBytes.Create(1, $80);
      4: Value := TBytes.Create(1, $C0, $80);
      5: Value := TBytes.Create(1, $E0, $80, $80);
    end;
    Reader := TBleGattReader.Create(Value);
    Reader.UInt(1);
    AssertEquals('', Reader.Utf8Text);
    AssertFalse(Reader.Valid);
    AssertEquals(1, Reader.Position);
  end;
end;

procedure TLazBleGattReaderTest.FinishedRequiresExactConsumption;
var
  Reader: TBleGattReader;
begin
  Reader := TBleGattReader.Create(TBytes.Create(1, 2));
  Reader.UInt(1);
  AssertFalse(Reader.Finished);
  Reader.UInt(1);
  AssertTrue(Reader.Finished);
end;

initialization
  RegisterTest(TLazBleGattReaderTest);

end.
