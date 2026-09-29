unit LazBleNativeDriverTests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry, SimpleBle,
  LazBleTypes, LazBleSimpleBleDriverIntf;

type
  TNativeDriverTest = class(TTestCase)
  private
    FDriver: ILazBleSimpleBleDriver;
    FSink: ILazBleSimpleBleDriverEventSink;
    function RunCommand(AKind: TLazBleBackendCommandKind; out ACode: Integer;
      out AMessage: string; AGeneration: QWord = 1): Boolean;
    procedure ScanAndConnect;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure NativeErrorCodeZeroAndMessage;
    procedure MissingAdapterGetsLazBleErrorCode;
    procedure UnknownAdapterGetsLazBleErrorCode;
    procedure DisabledBluetoothGetsLazBleErrorCode;
    procedure EmptyReadReleasesBuffer;
    procedure DiscoveryCopiesNestedGattData;
    procedure FailedDiscoveryReleasesPartialService;
    procedure ScanConnectCancelAndReconnect;
    procedure ShutdownUnsubscribesBeforeReleasingHandle;
  end;

implementation

uses
  LazBleSimpleBleBackend;

type
  TFakeError = record
    Code: TSimpleBleErr;
    Message: AnsiString;
  end;
  PFakeError = ^TFakeError;

  TCollectingSink = class(TInterfacedObject, ILazBleSimpleBleDriverEventSink)
  public
    Events: array of TLazBleBackendEvent;
    procedure Emit(const AEvent: TLazBleBackendEvent);
    function Count(AKind: TLazBleBackendEventKind): Integer;
    function Last(AKind: TLazBleBackendEventKind): TLazBleBackendEvent;
  end;

  TScanThread = class(TThread)
  public
    Driver: ILazBleSimpleBleDriver;
    Sink: ILazBleSimpleBleDriverEventSink;
    Succeeded: Boolean;
    ErrorCode: Integer;
    ErrorMessage: string;
    procedure Execute; override;
  end;

var
  SinkObject: TCollectingSink;
  ScanStarted: TEvent;
  ScanStartCallback, ScanStopCallback: TSimpleBleCallbackScanStart;
  ScanFoundCallback: TSimpleBleCallbackScanFound;
  ScanStartData, ScanStopData, ScanFoundData: Pointer;
  DisconnectCallback: TSimpleBleCallbackOnDisconnected;
  DisconnectData: Pointer;
  NotifyCallback: TSimpleBleCallbackNotify;
  NotifyData: Pointer;
  FailScan, FailSecondService, EmitScanResult: Boolean;
  AdapterCountValue: NativeUInt;
  BluetoothEnabled: Boolean;
  ScanActive, Connected: Boolean;
  ErrorReleases, ServiceReleases, BufferReleases: Integer;
  PeripheralReleases, AdapterReleases, Unsubscribes, Disconnects: Integer;
  Connects, ScanStops: Integer;
  ReleasedAfterUnsubscribe, UnsubscribedWhileConnected: Boolean;
  LastReadBuffer: Pointer;

procedure MakeError(var AError: TSimpleBleError; ACode: TSimpleBleErr;
  const AMessage: AnsiString);
var
  Value: PFakeError;
begin
  New(Value);
  Value^.Code := ACode;
  Value^.Message := AMessage;
  AError := Value;
end;

function FakeErrorCode(AError: TSimpleBleError): TSimpleBleErr; cdecl;
begin
  Result := PFakeError(AError)^.Code;
end;

function FakeErrorMessage(AError: TSimpleBleError): PChar; cdecl;
begin
  Result := PChar(PFakeError(AError)^.Message);
end;

procedure FakeErrorRelease(var AError: TSimpleBleError); cdecl;
begin
  Dispose(PFakeError(AError));
  AError := nil;
  Inc(ErrorReleases);
end;

function CopyCString(const AValue: AnsiString): PChar;
begin
  GetMem(Result, Length(AValue) + 1);
  Move(PChar(AValue)^, Result^, Length(AValue) + 1);
end;

procedure FakeFree(AValue: Pointer); cdecl;
begin
  if AValue = LastReadBuffer then
  begin
    Inc(BufferReleases);
    LastReadBuffer := nil;
  end;
  FreeMem(AValue);
end;

function AdapterCount(var AError: TSimpleBleError): NativeUInt; cdecl;
begin
  Result := AdapterCountValue;
end;

function IsBluetoothEnabled(var AError: TSimpleBleError): Boolean; cdecl;
begin
  Result := BluetoothEnabled;
end;

function AdapterHandle(AIndex: NativeUInt;
  var AError: TSimpleBleError): TSimpleBleAdapter; cdecl;
begin
  Result := Pointer(1);
end;

procedure ReleaseAdapter(AHandle: TSimpleBleAdapter); cdecl;
begin
  Inc(AdapterReleases);
end;

function AdapterIdentifier(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError): PChar; cdecl;
begin
  Result := CopyCString('fixture-adapter');
end;

function AdapterAddress(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError): PChar; cdecl;
begin
  Result := CopyCString('11:22:33:44:55:66');
end;

procedure SetScanStart(AHandle: TSimpleBleAdapter;
  ACallback: TSimpleBleCallbackScanStart; AData: Pointer); cdecl;
begin
  ScanStartCallback := ACallback;
  ScanStartData := AData;
end;

procedure SetScanStop(AHandle: TSimpleBleAdapter;
  ACallback: TSimpleBleCallbackScanStop; AData: Pointer); cdecl;
begin
  ScanStopCallback := ACallback;
  ScanStopData := AData;
end;

procedure SetScanFound(AHandle: TSimpleBleAdapter;
  ACallback: TSimpleBleCallbackScanFound; AData: Pointer); cdecl;
begin
  ScanFoundCallback := ACallback;
  ScanFoundData := AData;
end;

procedure StartScan(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError); cdecl;
var
  Peripheral: TSimpleBlePeripheral;
begin
  if FailScan then
  begin
    MakeError(AError, SIMPLEBLE_ERROR_INVALID_ARGUMENT, 'scan rejected');
    Exit;
  end;
  ScanActive := True;
  if Assigned(ScanStartCallback) then
    ScanStartCallback(AHandle, ScanStartData);
  if EmitScanResult and Assigned(ScanFoundCallback) then
  begin
    GetMem(Peripheral, 1);
    ScanFoundCallback(AHandle, Peripheral, ScanFoundData);
  end;
  ScanStarted.SetEvent;
end;

procedure StopScan(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError); cdecl;
begin
  ScanActive := False;
  Inc(ScanStops);
  if Assigned(ScanStopCallback) then
    ScanStopCallback(AHandle, ScanStopData);
end;

function IsScanActive(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError): Boolean; cdecl;
begin
  Result := ScanActive;
end;

function NoPeripherals(AHandle: TSimpleBleAdapter;
  var AError: TSimpleBleError): NativeUInt; cdecl;
begin
  Result := 0;
end;

function PeripheralAddress(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError): PChar; cdecl;
begin
  Result := CopyCString('AA:BB:CC:DD:EE:FF');
end;

function PeripheralIdentifier(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError): PChar; cdecl;
begin
  Result := CopyCString('fixture-device');
end;

function PeripheralRssi(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError): Int16; cdecl;
begin
  Result := -42;
end;

procedure ReleasePeripheral(AHandle: TSimpleBlePeripheral); cdecl;
begin
  ReleasedAfterUnsubscribe := (Unsubscribes = 1) and
    not Assigned(NotifyCallback);
  Inc(PeripheralReleases);
  FreeMem(AHandle);
end;

procedure SetDisconnected(AHandle: TSimpleBlePeripheral;
  ACallback: TSimpleBleCallbackOnConnected; AData: Pointer); cdecl;
begin
  DisconnectCallback := ACallback;
  DisconnectData := AData;
end;

function IsConnected(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError): Boolean; cdecl;
begin
  Result := Connected;
end;

procedure Connect(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError); cdecl;
begin
  Connected := True;
  Inc(Connects);
end;

procedure Disconnect(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError); cdecl;
begin
  Connected := False;
  Inc(Disconnects);
  if Assigned(DisconnectCallback) then
    DisconnectCallback(AHandle, DisconnectData);
end;

procedure PutUuid(var AUuid: TSimpleBleUuid; const AText: AnsiString);
begin
  AUuid := Default(TSimpleBleUuid);
  Move(PChar(AText)^, AUuid.Value[0], Length(AText));
end;

function ServicesCount(AHandle: TSimpleBlePeripheral;
  var AError: TSimpleBleError): NativeUInt; cdecl;
begin
  Result := 2;
end;

procedure GetService(AHandle: TSimpleBlePeripheral; AIndex: NativeUInt;
  var AService: TSimpleBleService; var AError: TSimpleBleError); cdecl;
var
  I, J, CharCount: Integer;
begin
  PutUuid(AService.Uuid, 'service-' + IntToStr(AIndex));
  AService.DataLength := 2;
  GetMem(AService.Data, 2);
  AService.Data[0] := Byte(AIndex);
  AService.Data[1] := 7;
  if AIndex = 0 then CharCount := 2 else CharCount := 1;
  AService.CharacteristicCount := CharCount;
  AService.Characteristics := AllocMem(CharCount * SizeOf(TSimpleBleCharacteristic));
  for I := 0 to CharCount - 1 do
  begin
    PutUuid(AService.Characteristics[I].Uuid,
      'char-' + IntToStr(AIndex) + '-' + IntToStr(I));
    AService.Characteristics[I].CanRead := True;
    AService.Characteristics[I].CanNotify := I = 0;
    AService.Characteristics[I].DescriptorCount := I + 1;
    AService.Characteristics[I].Descriptors :=
      AllocMem((I + 1) * SizeOf(TSimpleBleDescriptor));
    for J := 0 to I do
      PutUuid(AService.Characteristics[I].Descriptors[J].Uuid,
        'desc-' + IntToStr(AIndex) + '-' + IntToStr(I) + '-' + IntToStr(J));
  end;
  if FailSecondService and (AIndex = 1) then
    MakeError(AError, SIMPLEBLE_ERROR_OPERATION_FAILED, 'service rejected');
end;

procedure ReleaseService(var AService: TSimpleBleService); cdecl;
var
  I: Integer;
begin
  for I := 0 to AService.CharacteristicCount - 1 do
    FreeMem(AService.Characteristics[I].Descriptors);
  FreeMem(AService.Characteristics);
  FreeMem(AService.Data);
  AService := Default(TSimpleBleService);
  Inc(ServiceReleases);
end;

function ReadValue(AHandle: TSimpleBlePeripheral; AService,
  ACharacteristic: TSimpleBleUuid; var ALength: NativeUInt;
  var AError: TSimpleBleError): PByte; cdecl;
begin
  ALength := 0;
  GetMem(Result, 1);
  LastReadBuffer := Result;
end;

procedure Subscribe(AHandle: TSimpleBlePeripheral; AService,
  ACharacteristic: TSimpleBleUuid; ACallback: TSimpleBleCallbackNotify;
  AData: Pointer; var AError: TSimpleBleError); cdecl;
begin
  NotifyCallback := ACallback;
  NotifyData := AData;
end;

procedure Unsubscribe(AHandle: TSimpleBlePeripheral; AService,
  ACharacteristic: TSimpleBleUuid; var AError: TSimpleBleError); cdecl;
var
  LateCallback: TSimpleBleCallbackNotify;
  LateData: Pointer;
  Value: Byte;
begin
  UnsubscribedWhileConnected := Connected;
  Inc(Unsubscribes);
  LateCallback := NotifyCallback;
  LateData := NotifyData;
  NotifyCallback := nil;
  NotifyData := nil;
  if Assigned(LateCallback) then
  begin
    Value := 42;
    LateCallback(AHandle, AService, ACharacteristic, @Value, 1, LateData);
  end;
end;

procedure TCollectingSink.Emit(const AEvent: TLazBleBackendEvent);
begin
  SetLength(Events, Length(Events) + 1);
  Events[High(Events)] := AEvent;
end;

function TCollectingSink.Count(AKind: TLazBleBackendEventKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Events) do
    if Events[I].Kind = AKind then Inc(Result);
end;

function TCollectingSink.Last(AKind: TLazBleBackendEventKind): TLazBleBackendEvent;
var
  I: Integer;
begin
  Result := Default(TLazBleBackendEvent);
  for I := High(Events) downto 0 do
    if Events[I].Kind = AKind then Exit(Events[I]);
end;

procedure TScanThread.Execute;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan;
  Command.TimeoutMs := 10000;
  Succeeded := Driver.Execute(Command, 100, Sink, ErrorCode, ErrorMessage);
end;

procedure InstallFixture;
begin
  SimpleBleErrorCode := @FakeErrorCode;
  SimpleBleErrorMessage := @FakeErrorMessage;
  SimpleBleErrorRelease := @FakeErrorRelease;
  SimpleBleFree := @FakeFree;
  SimpleBleAdapterGetCount := @AdapterCount;
  SimpleBleAdapterIsBluetoothEnabled := @IsBluetoothEnabled;
  SimpleBleAdapterGetHandle := @AdapterHandle;
  SimpleBleAdapterReleaseHandle := @ReleaseAdapter;
  SimpleBleAdapterIdentifier := @AdapterIdentifier;
  SimpleBleAdapterAddress := @AdapterAddress;
  SimpleBleAdapterSetCallbackOnScanStart := @SetScanStart;
  SimpleBleAdapterSetCallbackOnScanStop := @SetScanStop;
  SimpleBleAdapterSetCallbackOnScanFound := @SetScanFound;
  SimpleBleAdapterSetCallbackOnScanUpdated := @SetScanFound;
  SimpleBleAdapterScanStart := @StartScan;
  SimpleBleAdapterScanStop := @StopScan;
  SimpleBleAdapterScanIsActive := @IsScanActive;
  SimpleBleAdapterGetConnectedPeripheralsCount := @NoPeripherals;
  SimpleBleAdapterGetPairedPeripheralsCount := @NoPeripherals;
  SimpleBlePeripheralAddress := @PeripheralAddress;
  SimpleBlePeripheralIdentifier := @PeripheralIdentifier;
  SimpleBlePeripheralRssi := @PeripheralRssi;
  SimpleBlePeripheralReleaseHandle := @ReleasePeripheral;
  SimpleBlePeripheralSetCallbackOnDisconnected := @SetDisconnected;
  SimpleBlePeripheralIsConnected := @IsConnected;
  SimpleBlePeripheralConnect := @Connect;
  SimpleBlePeripheralDisconnect := @Disconnect;
  SimpleBlePeripheralServicesCount := @ServicesCount;
  SimpleBlePeripheralServicesGet := @GetService;
  SimpleBleServiceRelease := @ReleaseService;
  SimpleBlePeripheralRead := @ReadValue;
  SimpleBlePeripheralNotify := @Subscribe;
  SimpleBlePeripheralUnsubscribe := @Unsubscribe;
end;

procedure TNativeDriverTest.SetUp;
begin
  inherited SetUp;
  ScanStarted := TEvent.Create(nil, True, False, '');
  ScanStartCallback := nil;
  ScanStopCallback := nil;
  ScanFoundCallback := nil;
  DisconnectCallback := nil;
  NotifyCallback := nil;
  FailScan := False;
  FailSecondService := False;
  EmitScanResult := True;
  AdapterCountValue := 1;
  BluetoothEnabled := True;
  ScanActive := False;
  Connected := False;
  ErrorReleases := 0;
  ServiceReleases := 0;
  BufferReleases := 0;
  PeripheralReleases := 0;
  AdapterReleases := 0;
  Unsubscribes := 0;
  Disconnects := 0;
  Connects := 0;
  ScanStops := 0;
  ReleasedAfterUnsubscribe := False;
  UnsubscribedWhileConnected := False;
  LastReadBuffer := nil;
  InstallFixture;
  SinkObject := TCollectingSink.Create;
  FSink := SinkObject;
  FDriver := CreateNativeSimpleBleDriverForTests;
end;

procedure TNativeDriverTest.TearDown;
begin
  FDriver.Close;
  FDriver := nil;
  FSink := nil;
  SinkObject := nil;
  ScanStarted.Free;
  SimpleBleUnloadLibrary;
  inherited TearDown;
end;

function TNativeDriverTest.RunCommand(AKind: TLazBleBackendCommandKind;
  out ACode: Integer; out AMessage: string; AGeneration: QWord): Boolean;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := AKind;
  Command.Generation := AGeneration;
  Command.TimeoutMs := 0;
  Command.DeviceId := 'AA:BB:CC:DD:EE:FF';
  Command.ServiceUuid := '180f';
  Command.CharacteristicUuid := '2a19';
  Result := FDriver.Execute(Command, 10, FSink, ACode, AMessage);
end;

procedure TNativeDriverTest.ScanAndConnect;
var
  Code: Integer;
  MessageText: string;
begin
  AssertTrue(RunCommand(lbckStartScan, Code, MessageText));
  AssertEquals(1, SinkObject.Count(lbekScanResult));
  AssertTrue(RunCommand(lbckConnect, Code, MessageText));
end;

procedure TNativeDriverTest.NativeErrorCodeZeroAndMessage;
var
  Code: Integer;
  MessageText: string;
begin
  FailScan := True;
  AssertFalse(RunCommand(lbckStartScan, Code, MessageText));
  AssertEquals(0, Code);
  AssertEquals('scan rejected', MessageText);
  AssertEquals(1, ErrorReleases);
  AssertEquals(0, SinkObject.Count(lbekScanStarted));
end;

procedure TNativeDriverTest.MissingAdapterGetsLazBleErrorCode;
var
  Code: Integer;
  MessageText: string;
begin
  AdapterCountValue := 0;
  AssertFalse(RunCommand(lbckCheckAvailability, Code, MessageText));
  AssertEquals(LazBleErrorNoAdapter, Code);
  AssertEquals('No BLE adapter was found', MessageText);
end;

procedure TNativeDriverTest.UnknownAdapterGetsLazBleErrorCode;
var
  Code: Integer;
  Command: TLazBleBackendCommand;
  MessageText: string;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckCheckAvailability;
  Command.AdapterId := 'another-adapter';
  AssertFalse(FDriver.Execute(Command, 10, FSink, Code, MessageText));
  AssertEquals(LazBleErrorAdapterNotFound, Code);
  AssertEquals('BLE adapter was not found: another-adapter', MessageText);
end;

procedure TNativeDriverTest.DisabledBluetoothGetsLazBleErrorCode;
var
  Code: Integer;
  MessageText: string;
begin
  BluetoothEnabled := False;
  AssertFalse(RunCommand(lbckCheckAvailability, Code, MessageText));
  AssertEquals(LazBleErrorBluetoothDisabled, Code);
  AssertEquals('Bluetooth is disabled', MessageText);
end;

procedure TNativeDriverTest.EmptyReadReleasesBuffer;
var
  Code: Integer;
  MessageText: string;
begin
  ScanAndConnect;
  AssertTrue(RunCommand(lbckRead, Code, MessageText));
  AssertEquals(1, SinkObject.Count(lbekReadResult));
  AssertEquals(0, Length(SinkObject.Last(lbekReadResult).Value));
  AssertEquals(1, BufferReleases);
end;

procedure TNativeDriverTest.DiscoveryCopiesNestedGattData;
var
  Code: Integer;
  MessageText: string;
  Event: TLazBleBackendEvent;
begin
  ScanAndConnect;
  AssertTrue(RunCommand(lbckDiscoverServices, Code, MessageText));
  AssertEquals(2, ServiceReleases);
  Event := SinkObject.Last(lbekServicesDiscovered);
  AssertEquals(2, Length(Event.Services));
  AssertEquals('service-0', Event.Services[0].Uuid);
  AssertEquals(2, Length(Event.Services[0].Characteristics));
  AssertEquals('char-0-1', Event.Services[0].Characteristics[1].Uuid);
  AssertEquals(2, Length(Event.Services[0].Characteristics[1].Descriptors));
  AssertEquals('desc-0-1-1', Event.Services[0].Characteristics[1].Descriptors[1].Uuid);
  AssertEquals(1, Length(Event.Services[1].Characteristics));
  AssertEquals('desc-1-0-0', Event.Services[1].Characteristics[0].Descriptors[0].Uuid);
  AssertEquals(7, Event.Services[1].Data[1]);
  AssertTrue(lbgcpNotify in Event.Services[0].Characteristics[0].Properties);
end;

procedure TNativeDriverTest.FailedDiscoveryReleasesPartialService;
var
  Code: Integer;
  MessageText: string;
begin
  ScanAndConnect;
  FailSecondService := True;
  AssertFalse(RunCommand(lbckDiscoverServices, Code, MessageText));
  AssertEquals(Ord(SIMPLEBLE_ERROR_OPERATION_FAILED), Code);
  AssertEquals('service rejected', MessageText);
  AssertEquals(2, ServiceReleases);
  AssertEquals(1, ErrorReleases);
  AssertEquals(0, SinkObject.Count(lbekServicesDiscovered));
end;

procedure TNativeDriverTest.ScanConnectCancelAndReconnect;
var
  Code: Integer;
  MessageText: string;
  Worker: TScanThread;
begin
  ScanAndConnect;
  AssertEquals(1, Connects);
  AssertTrue(RunCommand(lbckDisconnect, Code, MessageText));
  AssertTrue(RunCommand(lbckConnect, Code, MessageText, 2));
  AssertEquals(2, Connects);
  AssertEquals(2, SinkObject.Count(lbekConnected));
  AssertEquals(1, SinkObject.Count(lbekDisconnected));
  AssertEquals(Int64(2), Int64(SinkObject.Last(lbekConnected).Generation));
  EmitScanResult := False;
  ScanStarted.ResetEvent;
  Worker := TScanThread.Create(True);
  try
    Worker.FreeOnTerminate := False;
    Worker.Driver := FDriver;
    Worker.Sink := FSink;
    Worker.Start;
    AssertEquals(Ord(wrSignaled), Ord(ScanStarted.WaitFor(2000)));
    FDriver.CancelCurrent;
    Worker.WaitFor;
    AssertTrue(Worker.Succeeded);
    AssertEquals(2, ScanStops);
    AssertEquals(2, SinkObject.Count(lbekScanStopped));
  finally
    Worker.Free;
  end;
end;

procedure TNativeDriverTest.ShutdownUnsubscribesBeforeReleasingHandle;
var
  Code: Integer;
  MessageText: string;
begin
  ScanAndConnect;
  AssertTrue(RunCommand(lbckSubscribe, Code, MessageText));
  AssertEquals(1, SinkObject.Count(lbekSubscribed));
  AssertTrue(Assigned(NotifyCallback));
  FDriver.Close;
  AssertEquals(1, Unsubscribes);
  AssertEquals(1, Disconnects);
  AssertEquals(1, PeripheralReleases);
  AssertEquals(1, AdapterReleases);
  AssertTrue(UnsubscribedWhileConnected);
  AssertTrue(ReleasedAfterUnsubscribe);
  AssertFalse(Assigned(NotifyCallback));
  AssertFalse(Assigned(DisconnectCallback));
  AssertEquals(0, SinkObject.Count(lbekNotification));
end;

initialization
  RegisterTest(TNativeDriverTest);

end.
