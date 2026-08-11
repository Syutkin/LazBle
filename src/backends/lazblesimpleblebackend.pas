unit LazBleSimpleBleBackend;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleSimpleBleDriverIntf;

type
  TLazBleSimpleBleBackend = class;

  TLazBleSimpleBleBackend = class(TInterfacedObject, ILazBleBackend)
  private type
    TBackendOperation = class
      OperationId: TBleOperationId;
      Command: TLazBleBackendCommand;
      CancelRequested: Boolean;
      Started: Boolean;
      TerminalDelivered: Boolean;
    end;

    TQueuedEvent = class
      BackendEvent: TLazBleBackendEvent;
    end;

    TBackendWorker = class(TThread)
    private
      FBackend: TLazBleSimpleBleBackend;
    protected
      procedure Execute; override;
    public
      constructor Create(const ABackend: TLazBleSimpleBleBackend);
    end;
  private
    FLock: TRTLCriticalSection;
    FWorkEvent: PRTLEvent;
    FBackendEventSink: ILazBleBackendEventSink;
    FDriver: ILazBleSimpleBleDriver;
    FDriverEventSink: ILazBleSimpleBleDriverEventSink;
    FDriverEventSinkControl: ILazBleSimpleBleDriverSinkControl;
    FWorker: TBackendWorker;
    FOperations: TList;
    FPendingOperations: TList;
    FPendingEvents: TList;
    FNextOperationId: TBleOperationId;
    FCurrentOperation: TBackendOperation;
    FShutdownOperationId: TBleOperationId;
    FShutdownRequested: Boolean;
    FShutdownCompleted: Boolean;
    function AllocateOperationIdLocked: TBleOperationId;
    function FindOperationLocked(const AOperationId: TBleOperationId):
      TBackendOperation;
    function PopOperation: TBackendOperation;
    function PopEvent: TQueuedEvent;
    function AllOperationsTerminalLocked: Boolean;
    procedure QueueDriverEvent(const AEvent: TLazBleBackendEvent);
    procedure Deliver(const AEvent: TLazBleBackendEvent);
    procedure DrainEvents;
    procedure CompleteOperation(const AOperation: TBackendOperation;
      const ASucceeded: Boolean; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure ProcessOperation(const AOperation: TBackendOperation);
    procedure WorkerExecute;
  protected
    constructor Create(const ADriver: ILazBleSimpleBleDriver); overload;
  public
    constructor Create; overload;
    destructor Destroy; override;
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
  end;

implementation

uses
  Contnrs,
  SimpleBle;

type
  TLazBleSimpleBleDriverSink = class(TInterfacedObject,
    ILazBleSimpleBleDriverEventSink, ILazBleSimpleBleDriverSinkControl)
  private
    FBackend: TLazBleSimpleBleBackend;
  public
    constructor Create(const ABackend: TLazBleSimpleBleBackend);
    procedure Detach;
    procedure Emit(const AEvent: TLazBleBackendEvent);
  end;

  TLazBleNativeSimpleBleDriver = class;

  TSimpleBlePeripheralEntry = class
    Owner: TLazBleNativeSimpleBleDriver;
    Handle: TSimpleBlePeripheral;
    DeviceId: string;
    DeviceName: string;
    Generation: QWord;
    DisconnectRequested: Boolean;
  end;

  TSimpleBleSubscriptionEntry = class
    Owner: TLazBleNativeSimpleBleDriver;
    Peripheral: TSimpleBlePeripheralEntry;
    SubscriptionId: TBleSubscriptionId;
    ServiceUuid: string;
    CharacteristicUuid: string;
  end;

  TLazBleNativeSimpleBleDriver = class(TInterfacedObject,
    ILazBleSimpleBleDriver)
  private
    FLoaded: Boolean;
    FAdapter: TSimpleBleAdapter;
    FAdapterId: string;
    FOperationId: TBleOperationId;
    FEventSink: ILazBleSimpleBleDriverEventSink;
    FPeripherals: TObjectList;
    FSubscriptions: TObjectList;
    FNextSubscriptionId: TBleSubscriptionId;
    FCurrentCommandKind: TLazBleBackendCommandKind;
    function LoadLibrary(out AErrorMessage: string): Boolean;
    function SelectAdapter(const ARequestedId: string;
      out AErrorMessage: string): Boolean;
    procedure ScanStarted;
    procedure ScanStopped;
    procedure ScanResult(const APeripheral: TSimpleBlePeripheral);
    procedure PeripheralDisconnected(const AEntry: TSimpleBlePeripheralEntry);
    procedure NotificationReceived(const ASubscription:
      TSimpleBleSubscriptionEntry; const AData: PByte;
      const ADataLength: NativeUInt);
    function FindPeripheral(const ADeviceId: string):
      TSimpleBlePeripheralEntry;
    function FindSubscription(const ASubscriptionId: TBleSubscriptionId):
      TSimpleBleSubscriptionEntry;
    function ExecuteScan(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteAvailability(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteConnect(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteDisconnect(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteDiscovery(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteRead(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteWrite(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteSubscribe(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function ExecuteUnsubscribe(const ACommand: TLazBleBackendCommand;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(out AErrorMessage: string): Boolean;
    procedure Close;
    function Execute(const ACommand: TLazBleBackendCommand;
      const AOperationId: TBleOperationId;
      const AEventSink: ILazBleSimpleBleDriverEventSink;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    procedure CancelCurrent;
  end;

function CopyAndFreeNativeString(const AValue: PChar): string;
begin
  if AValue = nil then
    Exit('');
  try
    Result := StrPas(AValue);
  finally
    SimpleBleFree(AValue);
  end;
end;

function TryCreateNativeUuid(const AValue: string;
  out ANativeUuid: TSimpleBleUuid): Boolean;
var
  NormalizedValue: string;
begin
  ANativeUuid := Default(TSimpleBleUuid);
  NormalizedValue := LowerCase(Trim(AValue));
  Result := (NormalizedValue <> '') and
    (Length(NormalizedValue) < SIMPLEBLE_UUID_STR_LEN);
  if Result then
    Move(NormalizedValue[1], ANativeUuid.Value[0], Length(NormalizedValue));
end;

function CopyNativeUuid(const AValue: TSimpleBleUuid): string;
var
  ValueLength: Integer;
begin
  ValueLength := 0;
  while (ValueLength < SIMPLEBLE_UUID_STR_LEN) and
    (AValue.Value[ValueLength] <> #0) do
    Inc(ValueLength);
  SetString(Result, PChar(@AValue.Value[0]), ValueLength);
end;

procedure CopyNativeService(const ASource: TSimpleBleService;
  out ADestination: TLazBleGattService);
var
  CharacteristicCount: NativeUInt;
  CharacteristicIndex: NativeUInt;
  DataLength: NativeUInt;
  DescriptorCount: NativeUInt;
  DescriptorIndex: NativeUInt;
  NativeCharacteristic: TSimpleBleCharacteristic;
begin
  ADestination := Default(TLazBleGattService);
  ADestination.Uuid := CopyNativeUuid(ASource.Uuid);

  DataLength := ASource.DataLength;
  if DataLength > Length(ASource.Data) then
    DataLength := Length(ASource.Data);
  SetLength(ADestination.Data, DataLength);
  if DataLength > 0 then
    Move(ASource.Data[0], ADestination.Data[0], DataLength);

  CharacteristicCount := ASource.CharacteristicCount;
  if CharacteristicCount > Length(ASource.Characteristics) then
    CharacteristicCount := Length(ASource.Characteristics);
  SetLength(ADestination.Characteristics, CharacteristicCount);
  if CharacteristicCount > 0 then
    for CharacteristicIndex := 0 to CharacteristicCount - 1 do
    begin
      NativeCharacteristic := ASource.Characteristics[CharacteristicIndex];
      ADestination.Characteristics[CharacteristicIndex].Uuid :=
        CopyNativeUuid(NativeCharacteristic.Uuid);
      if NativeCharacteristic.CanRead then
        Include(ADestination.Characteristics[
          CharacteristicIndex].Properties, lbgcpRead);
      if NativeCharacteristic.CanWriteRequest then
        Include(ADestination.Characteristics[
          CharacteristicIndex].Properties, lbgcpWriteRequest);
      if NativeCharacteristic.CanWriteCommand then
        Include(ADestination.Characteristics[
          CharacteristicIndex].Properties, lbgcpWriteCommand);
      if NativeCharacteristic.CanNotify then
        Include(ADestination.Characteristics[
          CharacteristicIndex].Properties, lbgcpNotify);
      if NativeCharacteristic.CanIndicate then
        Include(ADestination.Characteristics[
          CharacteristicIndex].Properties, lbgcpIndicate);

      DescriptorCount := NativeCharacteristic.DescriptorCount;
      if DescriptorCount > Length(NativeCharacteristic.Descriptors) then
        DescriptorCount := Length(NativeCharacteristic.Descriptors);
      SetLength(ADestination.Characteristics[
        CharacteristicIndex].Descriptors, DescriptorCount);
      if DescriptorCount > 0 then
        for DescriptorIndex := 0 to DescriptorCount - 1 do
          ADestination.Characteristics[CharacteristicIndex].Descriptors[
            DescriptorIndex].Uuid := CopyNativeUuid(
              NativeCharacteristic.Descriptors[DescriptorIndex].Uuid);
    end;
end;

procedure NativeScanStarted(AAdapter: TSimpleBleAdapter;
  AUserData: Pointer); cdecl;
begin
  if AUserData <> nil then
    TLazBleNativeSimpleBleDriver(AUserData).ScanStarted;
end;

procedure NativeScanStopped(AAdapter: TSimpleBleAdapter;
  AUserData: Pointer); cdecl;
begin
  if AUserData <> nil then
    TLazBleNativeSimpleBleDriver(AUserData).ScanStopped;
end;

procedure NativeScanResult(AAdapter: TSimpleBleAdapter;
  APeripheral: TSimpleBlePeripheral; AUserData: Pointer); cdecl;
begin
  if AUserData <> nil then
    TLazBleNativeSimpleBleDriver(AUserData).ScanResult(APeripheral)
  else if APeripheral <> nil then
    SimpleBlePeripheralReleaseHandle(APeripheral);
end;

procedure NativePeripheralDisconnected(APeripheral: TSimpleBlePeripheral;
  AUserData: Pointer); cdecl;
begin
  if AUserData <> nil then
    TSimpleBlePeripheralEntry(AUserData).Owner.PeripheralDisconnected(
      TSimpleBlePeripheralEntry(AUserData));
end;

procedure NativeNotification(APeripheral: TSimpleBlePeripheral;
  AService: TSimpleBleUuid; ACharacteristic: TSimpleBleUuid; AData: PByte;
  ADataLength: NativeUInt; AUserData: Pointer); cdecl;
begin
  if AUserData <> nil then
    TSimpleBleSubscriptionEntry(AUserData).Owner.NotificationReceived(
      TSimpleBleSubscriptionEntry(AUserData), AData, ADataLength);
end;

constructor TLazBleNativeSimpleBleDriver.Create;
begin
  inherited Create;
  FPeripherals := TObjectList.Create(True);
  FSubscriptions := TObjectList.Create(True);
end;

destructor TLazBleNativeSimpleBleDriver.Destroy;
begin
  Close;
  FSubscriptions.Free;
  FPeripherals.Free;
  inherited Destroy;
end;

function TLazBleNativeSimpleBleDriver.LoadLibrary(
  out AErrorMessage: string): Boolean;
var
  LibraryDirectory: string;
begin
  if FLoaded then
    Exit(True);

  LibraryDirectory := GetEnvironmentVariable('SIMPLECBLE_LIBRARY_DIR');
  Result := (LibraryDirectory <> '') and
    SimpleBleLoadLibrary(LibraryDirectory);
  if not Result then
    Result := SimpleBleLoadLibrary(ExtractFilePath(ParamStr(0)));
  if not Result then
    Result := SimpleBleLoadLibrary;
  if Result then
  begin
    SimpleBlePinLibrary;
    FLoaded := True;
    AErrorMessage := '';
  end
  else
    AErrorMessage := SimpleBleGetLastLoadError;
end;

function TLazBleNativeSimpleBleDriver.SelectAdapter(
  const ARequestedId: string; out AErrorMessage: string): Boolean;
var
  Adapter: TSimpleBleAdapter;
  AdapterAddress: string;
  AdapterCount: NativeUInt;
  AdapterIdentifier: string;
  AdapterIndex: NativeUInt;
begin
  if FAdapter <> nil then
  begin
    Result := (ARequestedId = '') or SameText(ARequestedId, FAdapterId);
    if not Result then
      AErrorMessage := 'A different BLE adapter is already active: ' +
        FAdapterId;
    Exit;
  end;

  AdapterCount := SimpleBleAdapterGetCount();
  if AdapterCount = 0 then
  begin
    AErrorMessage := 'No BLE adapter was found';
    Exit(False);
  end;

  for AdapterIndex := 0 to AdapterCount - 1 do
  begin
    Adapter := SimpleBleAdapterGetHandle(AdapterIndex);
    if Adapter = nil then
      Continue;
    AdapterIdentifier := CopyAndFreeNativeString(
      SimpleBleAdapterIdentifier(Adapter));
    AdapterAddress := CopyAndFreeNativeString(SimpleBleAdapterAddress(Adapter));
    if (ARequestedId = '') or SameText(ARequestedId, AdapterIdentifier) or
      SameText(ARequestedId, AdapterAddress) then
    begin
      FAdapter := Adapter;
      if AdapterIdentifier <> '' then
        FAdapterId := AdapterIdentifier
      else
        FAdapterId := AdapterAddress;
      AErrorMessage := '';
      Exit(True);
    end;
    SimpleBleAdapterReleaseHandle(Adapter);
  end;

  AErrorMessage := 'BLE adapter was not found: ' + ARequestedId;
  Result := False;
end;

procedure TLazBleNativeSimpleBleDriver.ScanStarted;
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(FEventSink) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekScanStarted;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.AdapterId := FAdapterId;
  FEventSink.Emit(BackendEvent);
end;

procedure TLazBleNativeSimpleBleDriver.ScanStopped;
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(FEventSink) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekScanStopped;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.AdapterId := FAdapterId;
  FEventSink.Emit(BackendEvent);
end;

procedure TLazBleNativeSimpleBleDriver.ScanResult(
  const APeripheral: TSimpleBlePeripheral);
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  KeepHandle: Boolean;
begin
  if APeripheral = nil then
    Exit;
  KeepHandle := False;
  try
    if not Assigned(FEventSink) then
      Exit;
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekScanResult;
    BackendEvent.OperationId := FOperationId;
    BackendEvent.AdapterId := FAdapterId;
    BackendEvent.DeviceId := CopyAndFreeNativeString(
      SimpleBlePeripheralAddress(APeripheral));
    BackendEvent.DeviceName := CopyAndFreeNativeString(
      SimpleBlePeripheralIdentifier(APeripheral));
    BackendEvent.Rssi := SimpleBlePeripheralRssi(APeripheral);
    Entry := FindPeripheral(BackendEvent.DeviceId);
    if not Assigned(Entry) then
    begin
      Entry := TSimpleBlePeripheralEntry.Create;
      Entry.Owner := Self;
      Entry.Handle := APeripheral;
      Entry.DeviceId := BackendEvent.DeviceId;
      Entry.DeviceName := BackendEvent.DeviceName;
      FPeripherals.Add(Entry);
      KeepHandle := True;
    end
    else
      Entry.DeviceName := BackendEvent.DeviceName;
    FEventSink.Emit(BackendEvent);
  finally
    if not KeepHandle then
      SimpleBlePeripheralReleaseHandle(APeripheral);
  end;
end;

procedure TLazBleNativeSimpleBleDriver.PeripheralDisconnected(
  const AEntry: TSimpleBlePeripheralEntry);
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(FEventSink) or not Assigned(AEntry) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekDisconnected;
  if AEntry.DisconnectRequested and
    (FCurrentCommandKind = lbckDisconnect) then
    BackendEvent.OperationId := FOperationId
  else
    BackendEvent.OperationId := InvalidBleOperationId;
  BackendEvent.Generation := AEntry.Generation;
  BackendEvent.DeviceId := AEntry.DeviceId;
  AEntry.DisconnectRequested := False;
  FEventSink.Emit(BackendEvent);
end;

procedure TLazBleNativeSimpleBleDriver.NotificationReceived(
  const ASubscription: TSimpleBleSubscriptionEntry; const AData: PByte;
  const ADataLength: NativeUInt);
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(FEventSink) or not Assigned(ASubscription) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekNotification;
  BackendEvent.OperationId := InvalidBleOperationId;
  BackendEvent.SubscriptionId := ASubscription.SubscriptionId;
  BackendEvent.Generation := ASubscription.Peripheral.Generation;
  BackendEvent.DeviceId := ASubscription.Peripheral.DeviceId;
  BackendEvent.ServiceUuid := ASubscription.ServiceUuid;
  BackendEvent.CharacteristicUuid := ASubscription.CharacteristicUuid;
  SetLength(BackendEvent.Value, ADataLength);
  if (ADataLength > 0) and (AData <> nil) then
    Move(AData^, BackendEvent.Value[0], ADataLength);
  FEventSink.Emit(BackendEvent);
end;

function TLazBleNativeSimpleBleDriver.FindPeripheral(
  const ADeviceId: string): TSimpleBlePeripheralEntry;
var
  Index: Integer;
begin
  for Index := 0 to FPeripherals.Count - 1 do
  begin
    Result := TSimpleBlePeripheralEntry(FPeripherals[Index]);
    if SameText(Result.DeviceId, ADeviceId) then
      Exit;
  end;
  Result := nil;
end;

function TLazBleNativeSimpleBleDriver.FindSubscription(
  const ASubscriptionId: TBleSubscriptionId): TSimpleBleSubscriptionEntry;
var
  Index: Integer;
begin
  for Index := 0 to FSubscriptions.Count - 1 do
  begin
    Result := TSimpleBleSubscriptionEntry(FSubscriptions[Index]);
    if Result.SubscriptionId = ASubscriptionId then
      Exit;
  end;
  Result := nil;
end;

function TLazBleNativeSimpleBleDriver.Open(
  out AErrorMessage: string): Boolean;
begin
  Result := LoadLibrary(AErrorMessage);
end;

procedure TLazBleNativeSimpleBleDriver.Close;
var
  CharacteristicUuid: TSimpleBleUuid;
  Connected: Boolean;
  Entry: TSimpleBlePeripheralEntry;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  FOperationId := InvalidBleOperationId;
  while FSubscriptions.Count > 0 do
  begin
    Subscription := TSimpleBleSubscriptionEntry(
      FSubscriptions[FSubscriptions.Count - 1]);
    if FLoaded and TryCreateNativeUuid(Subscription.ServiceUuid,
      ServiceUuid) and TryCreateNativeUuid(Subscription.CharacteristicUuid,
      CharacteristicUuid) then
      SimpleBlePeripheralUnsubscribe(Subscription.Peripheral.Handle,
        ServiceUuid, CharacteristicUuid);
    FSubscriptions.Delete(FSubscriptions.Count - 1);
  end;
  while FPeripherals.Count > 0 do
  begin
    Entry := TSimpleBlePeripheralEntry(FPeripherals[FPeripherals.Count - 1]);
    if FLoaded and (Entry.Handle <> nil) then
    begin
      SimpleBlePeripheralSetCallbackOnDisconnected(Entry.Handle, nil, nil);
      Connected := False;
      if (SimpleBlePeripheralIsConnected(Entry.Handle, Connected) =
        SIMPLEBLE_SUCCESS) and Connected then
        SimpleBlePeripheralDisconnect(Entry.Handle);
      SimpleBlePeripheralReleaseHandle(Entry.Handle);
      Entry.Handle := nil;
    end;
    FPeripherals.Delete(FPeripherals.Count - 1);
  end;
  if FAdapter <> nil then
  begin
    SimpleBleAdapterSetCallbackOnScanStart(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanStop(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanFound(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter, nil, nil);
    SimpleBleAdapterReleaseHandle(FAdapter);
    FAdapter := nil;
  end;
  FAdapterId := '';
  FEventSink := nil;
  if FLoaded then
  begin
    SimpleBleUnloadLibrary;
    FLoaded := False;
  end;
end;

function TLazBleNativeSimpleBleDriver.ExecuteScan(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  NativeError: TSimpleBleErr;
  TimeoutMs: Integer;
begin
  Result := False;
  if not SelectAdapter(ACommand.AdapterId, AErrorMessage) then
    Exit;
  NativeError := SimpleBleAdapterSetCallbackOnScanStart(FAdapter,
    @NativeScanStarted, Self);
  if NativeError = SIMPLEBLE_SUCCESS then
    NativeError := SimpleBleAdapterSetCallbackOnScanStop(FAdapter,
      @NativeScanStopped, Self);
  if NativeError = SIMPLEBLE_SUCCESS then
    NativeError := SimpleBleAdapterSetCallbackOnScanFound(FAdapter,
      @NativeScanResult, Self);
  if NativeError = SIMPLEBLE_SUCCESS then
    NativeError := SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter,
      @NativeScanResult, Self);
  if NativeError <> SIMPLEBLE_SUCCESS then
  begin
    AErrorCode := Ord(NativeError);
    AErrorMessage := 'Could not register SimpleBLE scan callbacks';
    Exit;
  end;

  if ACommand.TimeoutMs > Cardinal(High(Integer)) then
    TimeoutMs := High(Integer)
  else
    TimeoutMs := ACommand.TimeoutMs;
  NativeError := SimpleBleAdapterScanFor(FAdapter, TimeoutMs);
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
    AErrorMessage := 'SimpleBLE scan failed';
end;

function TLazBleNativeSimpleBleDriver.ExecuteAvailability(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  AdapterError: string;
  BackendEvent: TLazBleBackendEvent;
  VersionValue: PChar;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekAvailabilityResult;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.BackendName := 'SimpleBLE';
  if Assigned(SimpleBleGetVersion) then
  begin
    VersionValue := SimpleBleGetVersion();
    if VersionValue <> nil then
      BackendEvent.BackendVersion := StrPas(VersionValue);
  end;
  BackendEvent.Available := SelectAdapter(ACommand.AdapterId, AdapterError);
  if BackendEvent.Available and not SimpleBleAdapterIsBluetoothEnabled() then
  begin
    BackendEvent.Available := False;
    AdapterError := 'Bluetooth is disabled';
  end;
  if BackendEvent.Available then
    BackendEvent.AdapterId := FAdapterId
  else
    BackendEvent.AdapterId := ACommand.AdapterId;
  FEventSink.Emit(BackendEvent);
  AErrorCode := Ord(SIMPLEBLE_SUCCESS);
  AErrorMessage := AdapterError;
  Result := BackendEvent.Available;
end;

function TLazBleNativeSimpleBleDriver.ExecuteConnect(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleErr;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device was not found by scan: ' + ACommand.DeviceId;
    Exit(False);
  end;
  NativeError := SimpleBlePeripheralSetCallbackOnDisconnected(Entry.Handle,
    @NativePeripheralDisconnected, Entry);
  if NativeError = SIMPLEBLE_SUCCESS then
    NativeError := SimpleBlePeripheralConnect(Entry.Handle);
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
  begin
    AErrorMessage := 'SimpleBLE connect failed';
    Exit;
  end;
  Entry.Generation := ACommand.Generation;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekConnected;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.Generation := Entry.Generation;
  BackendEvent.DeviceId := Entry.DeviceId;
  FEventSink.Emit(BackendEvent);
end;

function TLazBleNativeSimpleBleDriver.ExecuteDisconnect(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleErr;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  Entry.DisconnectRequested := True;
  NativeError := SimpleBlePeripheralDisconnect(Entry.Handle);
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
  begin
    Entry.DisconnectRequested := False;
    AErrorMessage := 'SimpleBLE disconnect failed';
    Exit;
  end;
  if Entry.DisconnectRequested then
  begin
    Entry.DisconnectRequested := False;
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekDisconnected;
    BackendEvent.OperationId := FOperationId;
    BackendEvent.Generation := Entry.Generation;
    BackendEvent.DeviceId := Entry.DeviceId;
    FEventSink.Emit(BackendEvent);
  end;
end;

function TLazBleNativeSimpleBleDriver.ExecuteDiscovery(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  Index: NativeUInt;
  NativeError: TSimpleBleErr;
  Service: TSimpleBleService;
  ServiceCount: NativeUInt;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  ServiceCount := SimpleBlePeripheralServicesCount(Entry.Handle);
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.Generation := Entry.Generation;
  BackendEvent.DeviceId := Entry.DeviceId;
  SetLength(BackendEvent.Services, ServiceCount);
  if ServiceCount > 0 then
    for Index := 0 to ServiceCount - 1 do
    begin
      Service := Default(TSimpleBleService);
      NativeError := SimpleBlePeripheralServicesGet(Entry.Handle, Index,
        Service);
      if NativeError <> SIMPLEBLE_SUCCESS then
      begin
        AErrorCode := Ord(NativeError);
        AErrorMessage := 'SimpleBLE service discovery failed';
        Exit(False);
      end;
      CopyNativeService(Service, BackendEvent.Services[Index]);
    end;
  AErrorCode := Ord(SIMPLEBLE_SUCCESS);
  Result := True;
  FEventSink.Emit(BackendEvent);
end;

function TLazBleNativeSimpleBleDriver.ExecuteRead(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  CharacteristicUuid: TSimpleBleUuid;
  Data: PByte;
  DataLength: NativeUInt;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleErr;
  ServiceUuid: TSimpleBleUuid;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  Data := nil;
  DataLength := 0;
  try
    NativeError := SimpleBlePeripheralRead(Entry.Handle, ServiceUuid,
      CharacteristicUuid, Data, DataLength);
    AErrorCode := Ord(NativeError);
    Result := NativeError = SIMPLEBLE_SUCCESS;
    if not Result then
    begin
      AErrorMessage := 'SimpleBLE read failed';
      Exit;
    end;
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekReadResult;
    BackendEvent.OperationId := FOperationId;
    BackendEvent.Generation := Entry.Generation;
    BackendEvent.DeviceId := Entry.DeviceId;
    BackendEvent.ServiceUuid := ACommand.ServiceUuid;
    BackendEvent.CharacteristicUuid := ACommand.CharacteristicUuid;
    SetLength(BackendEvent.Value, DataLength);
    if (DataLength > 0) and (Data <> nil) then
      Move(Data^, BackendEvent.Value[0], DataLength);
    FEventSink.Emit(BackendEvent);
  finally
    if Data <> nil then
      SimpleBleFree(Data);
  end;
end;

function TLazBleNativeSimpleBleDriver.ExecuteWrite(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  CharacteristicUuid: TSimpleBleUuid;
  Data: PByte;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleErr;
  ServiceUuid: TSimpleBleUuid;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  if Length(ACommand.Value) = 0 then
    Data := nil
  else
    Data := @ACommand.Value[0];
  if ACommand.WriteMode = lbwmCommand then
    NativeError := SimpleBlePeripheralWriteCommand(Entry.Handle,
      ServiceUuid, CharacteristicUuid, Data, Length(ACommand.Value))
  else
    NativeError := SimpleBlePeripheralWriteRequest(Entry.Handle,
      ServiceUuid, CharacteristicUuid, Data, Length(ACommand.Value));
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
  begin
    AErrorMessage := 'SimpleBLE write failed';
    Exit;
  end;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekWriteCompleted;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.Generation := Entry.Generation;
  BackendEvent.DeviceId := Entry.DeviceId;
  BackendEvent.ServiceUuid := ACommand.ServiceUuid;
  BackendEvent.CharacteristicUuid := ACommand.CharacteristicUuid;
  FEventSink.Emit(BackendEvent);
end;

function TLazBleNativeSimpleBleDriver.ExecuteSubscribe(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  CharacteristicUuid: TSimpleBleUuid;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleErr;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  Subscription := TSimpleBleSubscriptionEntry.Create;
  Subscription.Owner := Self;
  Subscription.Peripheral := Entry;
  Inc(FNextSubscriptionId);
  Subscription.SubscriptionId := FNextSubscriptionId;
  Subscription.ServiceUuid := ACommand.ServiceUuid;
  Subscription.CharacteristicUuid := ACommand.CharacteristicUuid;
  FSubscriptions.Add(Subscription);
  NativeError := SimpleBlePeripheralNotify(Entry.Handle, ServiceUuid,
    CharacteristicUuid, @NativeNotification, Subscription);
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
  begin
    FSubscriptions.Remove(Subscription);
    AErrorMessage := 'SimpleBLE subscribe failed';
    Exit;
  end;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekSubscribed;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.SubscriptionId := Subscription.SubscriptionId;
  BackendEvent.Generation := Entry.Generation;
  BackendEvent.DeviceId := Entry.DeviceId;
  BackendEvent.ServiceUuid := ACommand.ServiceUuid;
  BackendEvent.CharacteristicUuid := ACommand.CharacteristicUuid;
  FEventSink.Emit(BackendEvent);
end;

function TLazBleNativeSimpleBleDriver.ExecuteUnsubscribe(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  CharacteristicUuid: TSimpleBleUuid;
  NativeError: TSimpleBleErr;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  Subscription := FindSubscription(ACommand.SubscriptionId);
  if not Assigned(Subscription) then
  begin
    AErrorMessage := 'BLE subscription is not known';
    Exit(False);
  end;
  TryCreateNativeUuid(Subscription.ServiceUuid, ServiceUuid);
  TryCreateNativeUuid(Subscription.CharacteristicUuid, CharacteristicUuid);
  NativeError := SimpleBlePeripheralUnsubscribe(
    Subscription.Peripheral.Handle, ServiceUuid, CharacteristicUuid);
  AErrorCode := Ord(NativeError);
  Result := NativeError = SIMPLEBLE_SUCCESS;
  if not Result then
  begin
    AErrorMessage := 'SimpleBLE unsubscribe failed';
    Exit;
  end;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekUnsubscribed;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.SubscriptionId := Subscription.SubscriptionId;
  BackendEvent.Generation := Subscription.Peripheral.Generation;
  BackendEvent.DeviceId := Subscription.Peripheral.DeviceId;
  BackendEvent.ServiceUuid := Subscription.ServiceUuid;
  BackendEvent.CharacteristicUuid := Subscription.CharacteristicUuid;
  FEventSink.Emit(BackendEvent);
  FSubscriptions.Remove(Subscription);
end;

function TLazBleNativeSimpleBleDriver.Execute(
  const ACommand: TLazBleBackendCommand;
  const AOperationId: TBleOperationId;
  const AEventSink: ILazBleSimpleBleDriverEventSink;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
begin
  AErrorCode := 0;
  AErrorMessage := '';
  FOperationId := AOperationId;
  FEventSink := AEventSink;
  FCurrentCommandKind := ACommand.Kind;
  case ACommand.Kind of
    lbckCheckAvailability:
      Result := ExecuteAvailability(ACommand, AErrorCode, AErrorMessage);
    lbckStartScan:
      Result := ExecuteScan(ACommand, AErrorCode, AErrorMessage);
    lbckConnect:
      Result := ExecuteConnect(ACommand, AErrorCode, AErrorMessage);
    lbckDisconnect:
      Result := ExecuteDisconnect(ACommand, AErrorCode, AErrorMessage);
    lbckDiscoverServices:
      Result := ExecuteDiscovery(ACommand, AErrorCode, AErrorMessage);
    lbckRead:
      Result := ExecuteRead(ACommand, AErrorCode, AErrorMessage);
    lbckWrite:
      Result := ExecuteWrite(ACommand, AErrorCode, AErrorMessage);
    lbckSubscribe:
      Result := ExecuteSubscribe(ACommand, AErrorCode, AErrorMessage);
    lbckUnsubscribe:
      Result := ExecuteUnsubscribe(ACommand, AErrorCode, AErrorMessage);
  else
    begin
      AErrorMessage := 'SimpleBLE backend command is not implemented';
      Result := False;
    end;
  end;
  FOperationId := InvalidBleOperationId;
end;

procedure TLazBleNativeSimpleBleDriver.CancelCurrent;
begin
  if (FCurrentCommandKind = lbckStartScan) and (FAdapter <> nil) then
    SimpleBleAdapterScanStop(FAdapter);
end;

constructor TLazBleSimpleBleDriverSink.Create(
  const ABackend: TLazBleSimpleBleBackend);
begin
  inherited Create;
  FBackend := ABackend;
end;

procedure TLazBleSimpleBleDriverSink.Detach;
begin
  FBackend := nil;
end;

procedure TLazBleSimpleBleDriverSink.Emit(
  const AEvent: TLazBleBackendEvent);
begin
  if Assigned(FBackend) then
    FBackend.QueueDriverEvent(AEvent);
end;

constructor TLazBleSimpleBleBackend.TBackendWorker.Create(
  const ABackend: TLazBleSimpleBleBackend);
begin
  FBackend := ABackend;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TLazBleSimpleBleBackend.TBackendWorker.Execute;
begin
  FBackend.WorkerExecute;
end;

constructor TLazBleSimpleBleBackend.Create;
var
  Driver: ILazBleSimpleBleDriver;
begin
  Driver := TLazBleNativeSimpleBleDriver.Create;
  Create(Driver);
end;

constructor TLazBleSimpleBleBackend.Create(
  const ADriver: ILazBleSimpleBleDriver);
var
  DriverSink: TLazBleSimpleBleDriverSink;
begin
  inherited Create;
  if not Assigned(ADriver) then
    raise EArgumentNilException.Create('ADriver');
  InitCriticalSection(FLock);
  FWorkEvent := RTLEventCreate;
  FDriver := ADriver;
  FOperations := TList.Create;
  FPendingOperations := TList.Create;
  FPendingEvents := TList.Create;
  DriverSink := TLazBleSimpleBleDriverSink.Create(Self);
  FDriverEventSink := DriverSink;
  FDriverEventSinkControl := DriverSink;
  FWorker := TBackendWorker.Create(Self);
end;

destructor TLazBleSimpleBleBackend.Destroy;
var
  Index: Integer;
begin
  BeginShutdown;
  FWorker.WaitFor;
  FWorker.Free;
  FDriverEventSinkControl.Detach;
  FDriverEventSink := nil;
  FDriverEventSinkControl := nil;
  FDriver := nil;
  for Index := FPendingEvents.Count - 1 downto 0 do
    TObject(FPendingEvents[Index]).Free;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FPendingEvents.Free;
  FPendingOperations.Free;
  FOperations.Free;
  RTLEventDestroy(FWorkEvent);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TLazBleSimpleBleBackend.AllocateOperationIdLocked: TBleOperationId;
begin
  Inc(FNextOperationId);
  Result := FNextOperationId;
end;

function TLazBleSimpleBleBackend.FindOperationLocked(
  const AOperationId: TBleOperationId): TBackendOperation;
var
  Index: Integer;
begin
  for Index := 0 to FOperations.Count - 1 do
  begin
    Result := TBackendOperation(FOperations[Index]);
    if Result.OperationId = AOperationId then
      Exit;
  end;
  Result := nil;
end;

function TLazBleSimpleBleBackend.PopOperation: TBackendOperation;
begin
  EnterCriticalSection(FLock);
  try
    if FPendingOperations.Count = 0 then
      Exit(nil);
    Result := TBackendOperation(FPendingOperations[0]);
    FPendingOperations.Delete(0);
    Result.Started := True;
    FCurrentOperation := Result;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleSimpleBleBackend.PopEvent: TQueuedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FPendingEvents.Count = 0 then
      Exit(nil);
    Result := TQueuedEvent(FPendingEvents[0]);
    FPendingEvents.Delete(0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleSimpleBleBackend.AllOperationsTerminalLocked: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to FOperations.Count - 1 do
    if not TBackendOperation(FOperations[Index]).TerminalDelivered then
      Exit(False);
  Result := True;
end;

procedure TLazBleSimpleBleBackend.QueueDriverEvent(
  const AEvent: TLazBleBackendEvent);
var
  Operation: TBackendOperation;
  QueuedEvent: TQueuedEvent;
begin
  QueuedEvent := nil;
  EnterCriticalSection(FLock);
  try
    if FShutdownCompleted then
      Exit;
    if AEvent.OperationId <> InvalidBleOperationId then
    begin
      Operation := FindOperationLocked(AEvent.OperationId);
      if not Assigned(Operation) or Operation.TerminalDelivered then
        Exit;
    end;
    QueuedEvent := TQueuedEvent.Create;
    QueuedEvent.BackendEvent := AEvent;
    FPendingEvents.Add(QueuedEvent);
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(QueuedEvent) then
    RTLEventSetEvent(FWorkEvent);
end;

procedure TLazBleSimpleBleBackend.Deliver(
  const AEvent: TLazBleBackendEvent);
var
  EventSink: ILazBleBackendEventSink;
begin
  EnterCriticalSection(FLock);
  try
    EventSink := FBackendEventSink;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(EventSink) then
    EventSink.HandleBackendEvent(AEvent);
end;

procedure TLazBleSimpleBleBackend.DrainEvents;
var
  QueuedEvent: TQueuedEvent;
begin
  repeat
    QueuedEvent := PopEvent;
    if not Assigned(QueuedEvent) then
      Exit;
    try
      Deliver(QueuedEvent.BackendEvent);
    finally
      QueuedEvent.Free;
    end;
  until False;
end;

procedure TLazBleSimpleBleBackend.CompleteOperation(
  const AOperation: TBackendOperation; const ASucceeded: Boolean;
  const AErrorCode: Integer; const AErrorMessage: string);
var
  BackendEvent: TLazBleBackendEvent;
begin
  EnterCriticalSection(FLock);
  try
    if AOperation.TerminalDelivered then
      Exit;
    AOperation.TerminalDelivered := True;
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.OperationId := AOperation.OperationId;
    BackendEvent.Generation := AOperation.Command.Generation;
    BackendEvent.DeviceId := AOperation.Command.DeviceId;
    if AOperation.CancelRequested then
      BackendEvent.Kind := lbekOperationCancelled
    else if ASucceeded then
      BackendEvent.Kind := lbekOperationSucceeded
    else
    begin
      BackendEvent.Kind := lbekOperationFailed;
      BackendEvent.ErrorCode := AErrorCode;
      BackendEvent.ErrorMessage := AErrorMessage;
    end;
    if FCurrentOperation = AOperation then
      FCurrentOperation := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  Deliver(BackendEvent);
end;

procedure TLazBleSimpleBleBackend.ProcessOperation(
  const AOperation: TBackendOperation);
var
  ErrorCode: Integer;
  ErrorMessage: string;
  OpenError: string;
  Succeeded: Boolean;
begin
  if AOperation.CancelRequested then
  begin
    CompleteOperation(AOperation, False, 0, '');
    Exit;
  end;

  ErrorCode := 0;
  ErrorMessage := '';
  Succeeded := FDriver.Open(OpenError);
  if Succeeded then
    Succeeded := FDriver.Execute(AOperation.Command,
      AOperation.OperationId, FDriverEventSink, ErrorCode, ErrorMessage)
  else
    ErrorMessage := OpenError;
  DrainEvents;
  CompleteOperation(AOperation, Succeeded, ErrorCode, ErrorMessage);
end;

procedure TLazBleSimpleBleBackend.WorkerExecute;
var
  BackendEvent: TLazBleBackendEvent;
  Operation: TBackendOperation;
  ShouldShutdown: Boolean;
begin
  repeat
    RTLEventWaitFor(FWorkEvent);
    RTLEventResetEvent(FWorkEvent);
    DrainEvents;

    repeat
      Operation := PopOperation;
      if not Assigned(Operation) then
        Break;
      ProcessOperation(Operation);
      DrainEvents;
    until False;

    EnterCriticalSection(FLock);
    try
      ShouldShutdown := FShutdownRequested and
        AllOperationsTerminalLocked and not FShutdownCompleted;
    finally
      LeaveCriticalSection(FLock);
    end;
    if ShouldShutdown then
    begin
      FDriver.Close;
      BackendEvent := Default(TLazBleBackendEvent);
      BackendEvent.Kind := lbekShutdownCompleted;
      BackendEvent.OperationId := FShutdownOperationId;
      EnterCriticalSection(FLock);
      try
        FShutdownCompleted := True;
      finally
        LeaveCriticalSection(FLock);
      end;
      Deliver(BackendEvent);
      Exit;
    end;
  until False;
end;

procedure TLazBleSimpleBleBackend.SetEventSink(
  const AEventSink: ILazBleBackendEventSink);
begin
  EnterCriticalSection(FLock);
  try
    FBackendEventSink := AEventSink;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleSimpleBleBackend.Submit(
  const ACommand: TLazBleBackendCommand): TBleOperationId;
var
  Operation: TBackendOperation;
begin
  EnterCriticalSection(FLock);
  try
    if FShutdownRequested then
      Exit(InvalidBleOperationId);
    Operation := TBackendOperation.Create;
    Operation.OperationId := AllocateOperationIdLocked;
    Operation.Command := ACommand;
    FOperations.Add(Operation);
    FPendingOperations.Add(Operation);
    Result := Operation.OperationId;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWorkEvent);
end;

procedure TLazBleSimpleBleBackend.Cancel(
  const AOperationId: TBleOperationId);
var
  CancelCurrent: Boolean;
  Operation: TBackendOperation;
begin
  CancelCurrent := False;
  EnterCriticalSection(FLock);
  try
    Operation := FindOperationLocked(AOperationId);
    if not Assigned(Operation) or Operation.TerminalDelivered or
      Operation.CancelRequested then
      Exit;
    Operation.CancelRequested := True;
    CancelCurrent := FCurrentOperation = Operation;
  finally
    LeaveCriticalSection(FLock);
  end;
  if CancelCurrent then
    FDriver.CancelCurrent;
  RTLEventSetEvent(FWorkEvent);
end;

function TLazBleSimpleBleBackend.BeginShutdown: TBleOperationId;
var
  CancelCurrent: Boolean;
  Index: Integer;
begin
  CancelCurrent := False;
  EnterCriticalSection(FLock);
  try
    if FShutdownRequested then
      Exit(FShutdownOperationId);
    FShutdownRequested := True;
    FShutdownOperationId := AllocateOperationIdLocked;
    for Index := 0 to FOperations.Count - 1 do
      with TBackendOperation(FOperations[Index]) do
        if not TerminalDelivered then
          CancelRequested := True;
    CancelCurrent := Assigned(FCurrentOperation);
    Result := FShutdownOperationId;
  finally
    LeaveCriticalSection(FLock);
  end;
  if CancelCurrent then
    FDriver.CancelCurrent;
  RTLEventSetEvent(FWorkEvent);
end;

end.
