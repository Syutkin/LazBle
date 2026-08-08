unit BleExampleUtils;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

function TryParseBleTimeout(const AText: string;
  const ADefaultTimeoutMs: Cardinal; out ATimeoutMs: Cardinal): Boolean;
function SelectBleDevice(const ADevices: TBleDeviceInfos;
  const ARequestedDeviceId: string; out ADeviceId: string): Boolean;

implementation

uses
  SysUtils;

function TryParseBleTimeout(const AText: string;
  const ADefaultTimeoutMs: Cardinal; out ATimeoutMs: Cardinal): Boolean;
var
  ParsedValue: QWord;
begin
  if AText = '' then
  begin
    ATimeoutMs := ADefaultTimeoutMs;
    Exit(True);
  end;
  Result := TryStrToQWord(AText, ParsedValue) and
    (ParsedValue > 0) and (ParsedValue <= High(Cardinal));
  if Result then
    ATimeoutMs := ParsedValue;
end;

function SelectBleDevice(const ADevices: TBleDeviceInfos;
  const ARequestedDeviceId: string; out ADeviceId: string): Boolean;
var
  Index: Integer;
  Selection: Integer;
  SelectionText: string;
begin
  if ARequestedDeviceId <> '' then
  begin
    for Index := 0 to High(ADevices) do
      if SameText(ADevices[Index].DeviceId, ARequestedDeviceId) then
      begin
        ADeviceId := ADevices[Index].DeviceId;
        Exit(True);
      end;
    WriteLn('Device was not found during scan: ', ARequestedDeviceId);
    Exit(False);
  end;

  if Length(ADevices) = 0 then
  begin
    WriteLn('No BLE devices were found.');
    Exit(False);
  end;
  WriteLn('The following devices were found:');
  for Index := 0 to High(ADevices) do
    WriteLn('[', Index, '] ', ADevices[Index].DeviceName, ' [',
      ADevices[Index].DeviceId, '] ', ADevices[Index].Rssi, ' dBm');
  Write('Please select a device: ');
  ReadLn(SelectionText);
  Result := TryStrToInt(Trim(SelectionText), Selection) and
    (Selection >= 0) and (Selection < Length(ADevices));
  if Result then
    ADeviceId := ADevices[Selection].DeviceId
  else
    WriteLn('Invalid device selection.');
end;

end.
