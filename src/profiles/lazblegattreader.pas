unit LazBleGattReader;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  TBleGattValueState = (lgvsAbsent, lgvsFinite, lgvsUnknown,
    lgvsGreaterThan, lgvsLessThan, lgvsNaN, lgvsNotAtResolution,
    lgvsPositiveInfinity, lgvsNegativeInfinity);

  { Value is meaningful for Finite, GreaterThan and LessThan; otherwise read State. }
  TBleGattValue = record
    State: TBleGattValueState;
    Value: Double;
  end;

  { A bounded little-endian reader. Input bytes remain read-only while in use.
    Invalid reads latch Valid=False; recreate the reader to start another value.
    No BLE session, SDK or main-thread dependency. }
  TBleGattReader = record
  private
    FData: TBytes;
    FPosition: SizeInt;
    FValid: Boolean;
  public
    class function Create(const AData: TBytes): TBleGattReader; static;
    { Integer widths are 1..4 bytes. Failed reads return zero without advancing. }
    function UInt(const ABytes: Integer): Cardinal;
    function SInt(const ABytes: Integer): Integer;
    function UIntValue(const ABytes: Integer): TBleGattValue;
    { IEEE 11073 medfloat16/SFLOAT, not IEEE 754; no characteristic range policy. }
    function SFloat: TBleGattValue;
    { Validate and consume the remaining bytes as UTF-8. }
    function Utf8Text: UTF8String;
    function Finished: Boolean;
    procedure Invalidate;
    property Position: SizeInt read FPosition;
    property Valid: Boolean read FValid;
  end;

implementation

uses
  Math;

class function TBleGattReader.Create(const AData: TBytes): TBleGattReader;
begin
  Result.FData := AData;
  Result.FPosition := 0;
  Result.FValid := True;
end;

function TBleGattReader.UInt(const ABytes: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  if not FValid or (ABytes < 1) or (ABytes > 4) or
    (Length(FData) - FPosition < ABytes) then
  begin
    FValid := False;
    Exit;
  end;
  for I := 0 to ABytes - 1 do
  begin
    Result := Result or (Cardinal(FData[FPosition]) shl (8 * I));
    Inc(FPosition);
  end;
end;

function TBleGattReader.SInt(const ABytes: Integer): Integer;
var
  Raw: Cardinal;
begin
  Result := 0;
  Raw := UInt(ABytes);
  if not FValid then Exit;
  if (Raw and (Cardinal(1) shl (8 * ABytes - 1))) <> 0 then
    Result := Integer(Int64(Raw) - (Int64(1) shl (8 * ABytes)))
  else Result := Integer(Raw);
end;

function TBleGattReader.UIntValue(const ABytes: Integer): TBleGattValue;
var
  Raw: Cardinal;
begin
  Result := Default(TBleGattValue);
  Raw := UInt(ABytes);
  if not FValid then Exit;
  Result.State := lgvsFinite;
  Result.Value := Raw;
end;

function TBleGattReader.SFloat: TBleGattValue;
var
  Raw: Cardinal;
  Mantissa, Exponent: Integer;
begin
  Result := Default(TBleGattValue);
  Raw := UInt(2);
  if not FValid then Exit;
  case Raw of
    $07FE: Result.State := lgvsPositiveInfinity;
    $0802: Result.State := lgvsNegativeInfinity;
    $07FF: Result.State := lgvsNaN;
    $0800: Result.State := lgvsNotAtResolution;
    $0801: FValid := False;
  else
    Result.State := lgvsFinite;
    Mantissa := Raw and $FFF;
    if Mantissa >= $800 then Dec(Mantissa, $1000);
    Exponent := Raw shr 12;
    if Exponent >= 8 then Dec(Exponent, 16);
    Result.Value := Mantissa * IntPower(10.0, Exponent);
  end;
end;

function TBleGattReader.Utf8Text: UTF8String;
var
  I, J, Continuations: SizeInt;
  First, Next: Byte;
begin
  Result := '';
  if not FValid then Exit;
  I := FPosition;
  while I < Length(FData) do
  begin
    First := FData[I];
    if First <= $7F then Continuations := 0
    else if (First >= $C2) and (First <= $DF) then Continuations := 1
    else if (First >= $E0) and (First <= $EF) then Continuations := 2
    else if (First >= $F0) and (First <= $F4) then Continuations := 3
    else
    begin
      FValid := False;
      Exit;
    end;
    if Length(FData) - I <= Continuations then
    begin
      FValid := False;
      Exit;
    end;
    for J := 1 to Continuations do
    begin
      Next := FData[I + J];
      if (Next < $80) or (Next > $BF) or
        ((J = 1) and (((First = $E0) and (Next < $A0)) or
          ((First = $ED) and (Next > $9F)) or
          ((First = $F0) and (Next < $90)) or
          ((First = $F4) and (Next > $8F)))) then
      begin
        FValid := False;
        Exit;
      end;
    end;
    Inc(I, Continuations + 1);
  end;
  if I > FPosition then SetString(Result, PAnsiChar(@FData[FPosition]), I - FPosition);
  FPosition := I;
end;

function TBleGattReader.Finished: Boolean;
begin
  Result := FValid and (FPosition = Length(FData));
end;

procedure TBleGattReader.Invalidate;
begin
  FValid := False;
end;

end.
