unit BleExampleUtils;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

{ Main-thread line input that keeps delivering BLE callbacks. EOF returns False. }
function ReadBleConsoleLine(out ALine: string): Boolean;

function TryParseBleTimeout(const AText: string;
  const ADefaultTimeoutMs: Cardinal; out ATimeoutMs: Cardinal): Boolean;
function SelectBleDevice(const ADevices: TBleDeviceInfos;
  const ARequestedDeviceId: string; out ADeviceId: string): Boolean;

implementation

uses
  Classes,
  SysUtils
  {$IFDEF UNIX}, BaseUnix, UnixType{$ENDIF}
  {$IFDEF MSWINDOWS}, Windows{$ENDIF};

var
  SkipLineFeed: Boolean;

function ReadBleConsoleLine(out ALine: string): Boolean;
var
  Text: string;
  C: Char;
  {$IFDEF UNIX}
  ReadSet: TFDSet;
  Wait: TTimeVal;
  Count: Int64;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Handle: THandle;
  Mode, Count, Available: DWord;
  RecordValue: TInputRecord;
  IsConsole: Boolean;
  {$ENDIF}
begin
  ALine := '';
  {$IFDEF MSWINDOWS}
  Handle := GetStdHandle(STD_INPUT_HANDLE);
  IsConsole := GetConsoleMode(Handle, Mode);
  {$ENDIF}
  repeat
    CheckSynchronize(0);
    Text := '';
    {$IFDEF UNIX}
    fpFD_ZERO(ReadSet);
    fpFD_SET(StdInputHandle, ReadSet);
    Wait.tv_sec := 0;
    Wait.tv_usec := 0;
    Count := fpSelect(StdInputHandle + 1, @ReadSet, nil, nil, @Wait);
    if Count < 0 then
    begin
      if fpgeterrno = ESysEINTR then Continue;
      RaiseLastOSError;
    end;
    if Count = 0 then
    begin
      CheckSynchronize(10);
      Continue;
    end;
    Count := fpRead(StdInputHandle, C, 1);
    if Count = 0 then Exit(ALine <> '');
    if Count < 0 then
    begin
      if fpgeterrno = ESysEINTR then Continue;
      RaiseLastOSError;
    end;
    Text := C;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if IsConsole then
    begin
      if not GetNumberOfConsoleInputEvents(Handle, Count) then RaiseLastOSError;
      if Count = 0 then
      begin
        CheckSynchronize(10);
        Continue;
      end;
      if not ReadConsoleInputW(Handle, RecordValue, 1, Count) then RaiseLastOSError;
      if (RecordValue.EventType <> KEY_EVENT) or
        not RecordValue.Event.KeyEvent.bKeyDown then Continue;
      Text := UTF8Encode(UnicodeString(RecordValue.Event.KeyEvent.UnicodeChar));
      if (Text = '') or (Text = #0) then Continue;
      if Text = #8 then
      begin
        if ALine <> '' then
        begin
          while (Length(ALine) > 0) and (Ord(ALine[Length(ALine)]) in [$80..$BF]) do
            Delete(ALine, Length(ALine), 1);
          Delete(ALine, Length(ALine), 1);
          Write(#8' '#8);
        end;
        Continue;
      end;
      if Text = #13 then WriteLn else Write(Text);
    end
    else
    begin
      if GetFileType(Handle) = FILE_TYPE_PIPE then
      begin
        if not PeekNamedPipe(Handle, nil, 0, nil, @Available, nil) then
          Exit(ALine <> '');
        if Available = 0 then
        begin
          CheckSynchronize(10);
          Continue;
        end;
      end;
      if not ReadFile(Handle, C, 1, Count, nil) or (Count = 0) then
        Exit(ALine <> '');
      Text := C;
    end;
    {$ENDIF}
    if SkipLineFeed and (Text = #10) then
    begin
      SkipLineFeed := False;
      Continue;
    end;
    SkipLineFeed := Text = #13;
    if (Text = #10) or (Text = #13) then Exit(True);
    ALine := ALine + Text;
  until False;
end;


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
  if not ReadBleConsoleLine(SelectionText) then Exit(False);
  Result := TryStrToInt(Trim(SelectionText), Selection) and
    (Selection >= 0) and (Selection < Length(ADevices));
  if Result then
    ADeviceId := ADevices[Selection].DeviceId
  else
    WriteLn('Invalid device selection.');
end;

end.
