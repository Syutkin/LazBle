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
    procedure SignedIntegersPreserveAllWidthBoundaries;
    procedure RejectsInvalidWidthsAndShortBuffers;
    procedure FailedReaderStaysFailedUntilRecreated;
    procedure SFloatPreservesSignsDecimalScaleAndZero;
    procedure SFloatPreservesSpecialValues;
    procedure ReservedAndTruncatedSFloatFail;
    procedure UnsignedValueIsAbsentAfterFailedRead;
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
  AssertEquals($12, Reader.UInt(1));
  AssertEquals($5634, Reader.UInt(2));
  AssertEquals($BC9A78, Reader.UInt(3));
  AssertEquals($3412F0DE, Reader.UInt(4));
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
begin
  for Width := 1 to 4 do
  begin
    Value := nil;
    SetLength(Value, Width);
    Value[Width - 1] := $80;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(-(Int64(1) shl (Width * 8 - 1)), Int64(Reader.SInt(Width)));
    for I := 0 to Width - 1 do Value[I] := $FF;
    Value[Width - 1] := $7F;
    Reader := TBleGattReader.Create(Value);
    AssertEquals((Int64(1) shl (Width * 8 - 1)) - 1, Int64(Reader.SInt(Width)));
    Value[Width - 1] := $FF;
    Reader := TBleGattReader.Create(Value);
    AssertEquals(-1, Reader.SInt(Width));
    AssertTrue(Reader.Finished);
  end;
end;

procedure TLazBleGattReaderTest.RejectsInvalidWidthsAndShortBuffers;
var
  Reader: TBleGattReader;
  Width: Integer;
begin
  for Width := -1 to 5 do
  begin
    Reader := TBleGattReader.Create(TBytes.Create(1));
    if Width = 1 then Continue;
    AssertEquals(0, Reader.UInt(Width));
    AssertFalse(Reader.Valid);
    AssertEquals(0, Reader.Position);
  end;
end;

procedure TLazBleGattReaderTest.FailedReaderStaysFailedUntilRecreated;
var
  Reader: TBleGattReader;
begin
  Reader := TBleGattReader.Create(TBytes.Create(42));
  Reader.UInt(2);
  AssertEquals(0, Reader.UInt(1));
  AssertFalse(Reader.Valid);
  AssertFalse(Reader.Finished);
  Reader := TBleGattReader.Create(TBytes.Create(42));
  AssertEquals(42, Reader.UInt(1));
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
  AssertEquals($FF, Reader.UInt(1));
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
