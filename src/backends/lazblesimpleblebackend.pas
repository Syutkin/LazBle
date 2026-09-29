unit LazBleSimpleBleBackend;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
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

    TEventWorker = class(TThread)
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
    FEventWorkEvent: PRTLEvent;
    FBackendEventSink: ILazBleBackendEventSink;
    FDriver: ILazBleSimpleBleDriver;
    FDriverEventSink: ILazBleSimpleBleDriverEventSink;
    FDriverEventSinkControl: ILazBleSimpleBleDriverSinkControl;
    FWorker: TBackendWorker;
    FEventWorker: TEventWorker;
    FOperations: TList;
    FPendingOperations: TList;
    FPendingEvents: TList;
    FNextOperationId: TBleOperationId;
    FCurrentOperation: TBackendOperation;
    FShutdownOperationId: TBleOperationId;
    FShutdownRequested: Boolean;
    FShutdownCompleted: Boolean;
    FEventShutdownRequested: Boolean;
    function AllocateOperationIdLocked: TBleOperationId;
    function FindOperationLocked(const AOperationId: TBleOperationId):
      TBackendOperation;
    function PopOperation: TBackendOperation;
    function PopEvent: TQueuedEvent;
    function AllOperationsTerminalLocked: Boolean;
    procedure QueueEvent(const AEvent: TLazBleBackendEvent);
    procedure QueueDriverEvent(const AEvent: TLazBleBackendEvent);
    procedure Deliver(const AEvent: TLazBleBackendEvent);
    procedure DrainEvents;
    procedure CompleteOperation(const AOperation: TBackendOperation;
      const ASucceeded: Boolean; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure ProcessOperation(const AOperation: TBackendOperation);
    procedure WorkerExecute;
    procedure EventWorkerExecute;
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

{$IFDEF LAZBLE_NATIVE_TESTS}
function CreateNativeSimpleBleDriverForTests: ILazBleSimpleBleDriver;
{$ENDIF}

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
    DisconnectNotified: Boolean;
  end;

  TSimpleBleSubscriptionEntry = class
    Owner: TLazBleNativeSimpleBleDriver;
    Peripheral: TSimpleBlePeripheralEntry;
    Active: LongInt;
    SubscriptionId: TBleSubscriptionId;
    ServiceUuid: string;
    CharacteristicUuid: string;
  end;

  TLazBleNativeSimpleBleDriver = class(TInterfacedObject,
    ILazBleSimpleBleDriver)
  private
    FLoaded: Boolean;
    {$IFDEF LAZBLE_NATIVE_TESTS}
    FInjectedForTests: Boolean;
    {$ENDIF}
    FAdapter: TSimpleBleAdapter;
    FAdapterId: string;
    FOperationId: TBleOperationId;
    FEventSink: ILazBleSimpleBleDriverEventSink;
    FPeripherals: TObjectList;
    FSubscriptions: TObjectList;
    FNextSubscriptionId: TBleSubscriptionId;
    FCurrentCommandKind: TLazBleBackendCommandKind;
    FScanWaitEvent: TEvent;
    FTargetScanDeviceId: string;
    FCallbackLock: TCriticalSection;
    FCallbacksIdle: TEvent;
    FActiveCallbacks: Integer;
    FClosing: Boolean;
    FScanCallbacksActive: Boolean;
    function BeginCallback: Boolean;
    procedure EndCallback;
    function ScanCallbacksActive: Boolean;
    procedure SetScanCallbacksActive(const AActive: Boolean);
    procedure ClearScanCallbacks;
    function LoadLibrary(out AErrorMessage: string): Boolean;
    function SelectAdapter(const ARequestedId: string;
      out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    procedure ScanStarted;
    procedure ScanStopped;
    procedure ScanResult(var APeripheral: TSimpleBlePeripheral);
    procedure PeripheralDisconnected(const AEntry: TSimpleBlePeripheralEntry);
    procedure NotificationReceived(const ASubscription:
      TSimpleBleSubscriptionEntry; const AData: PByte;
      const ADataLength: NativeUInt);
    function FindPeripheral(const ADeviceId: string):
      TSimpleBlePeripheralEntry;
    function FindPeripheralLocked(const ADeviceId: string):
      TSimpleBlePeripheralEntry;
    function StorePeripheral(const APeripheral: TSimpleBlePeripheral;
      out AEntry: TSimpleBlePeripheralEntry;
      out AErrorCode: Integer; out AErrorMessage: string;
      const AExpectedDeviceId: string = ''): Boolean;
    function FindConnectedPeripheral(const ADeviceId: string;
      out AEntry: TSimpleBlePeripheralEntry; out AErrorCode: Integer;
      out AErrorMessage: string): Boolean;
    function FindPairedPeripheral(const ADeviceId: string;
      out AEntry: TSimpleBlePeripheralEntry; out AErrorCode: Integer;
      out AErrorMessage: string): Boolean;
    function ScanForPeripheral(const ADeviceId: string;
      out AEntry: TSimpleBlePeripheralEntry; out AErrorCode: Integer;
      out AErrorMessage: string): Boolean;
    function ResolvePeripheral(const ADeviceId: string;
      out AEntry: TSimpleBlePeripheralEntry; out AErrorCode: Integer;
      out AErrorMessage: string): Boolean;
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

const
  DefaultSimpleBlePeripheralDiscoveryTimeoutMs = 5000;

function ConsumeNativeError(var ANativeError: TSimpleBleError;
  out AErrorCode: Integer; out AErrorMessage: string;
  const AContext: string): Boolean;
var
  MessageValue: PChar;
begin
  AErrorCode := 0;
  AErrorMessage := '';
  Result := ANativeError = nil;
  if Result then
    Exit;
  try
    AErrorCode := Ord(SimpleBleErrorCode(ANativeError));
    MessageValue := SimpleBleErrorMessage(ANativeError);
    if MessageValue <> nil then
      AErrorMessage := StrPas(MessageValue);
    if AErrorMessage = '' then
      AErrorMessage := AContext;
  finally
    SimpleBleErrorRelease(ANativeError);
  end;
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
  CharacteristicIndex: SizeInt;
  DescriptorIndex: SizeInt;
  NativeService: TSimpleBleOwnedService;
begin
  ADestination := Default(TLazBleGattService);
  NativeService := SimpleBleCopyService(ASource);
  ADestination.Uuid := CopyNativeUuid(NativeService.Uuid);
  ADestination.Data := NativeService.Data;
  SetLength(ADestination.Characteristics,
    Length(NativeService.Characteristics));
  for CharacteristicIndex := 0 to High(NativeService.Characteristics) do
  begin
    ADestination.Characteristics[CharacteristicIndex].Uuid :=
      CopyNativeUuid(NativeService.Characteristics[CharacteristicIndex].Uuid);
    if NativeService.Characteristics[CharacteristicIndex].CanRead then
      Include(ADestination.Characteristics[
        CharacteristicIndex].Properties, lbgcpRead);
    if NativeService.Characteristics[CharacteristicIndex].CanWriteRequest then
      Include(ADestination.Characteristics[
        CharacteristicIndex].Properties, lbgcpWriteRequest);
    if NativeService.Characteristics[CharacteristicIndex].CanWriteCommand then
      Include(ADestination.Characteristics[
        CharacteristicIndex].Properties, lbgcpWriteCommand);
    if NativeService.Characteristics[CharacteristicIndex].CanNotify then
      Include(ADestination.Characteristics[
        CharacteristicIndex].Properties, lbgcpNotify);
    if NativeService.Characteristics[CharacteristicIndex].CanIndicate then
      Include(ADestination.Characteristics[
        CharacteristicIndex].Properties, lbgcpIndicate);

    SetLength(ADestination.Characteristics[
      CharacteristicIndex].Descriptors,
      Length(NativeService.Characteristics[CharacteristicIndex].Descriptors));
    for DescriptorIndex := 0 to High(
      NativeService.Characteristics[CharacteristicIndex].Descriptors) do
      ADestination.Characteristics[CharacteristicIndex].Descriptors[
        DescriptorIndex].Uuid := CopyNativeUuid(
          NativeService.Characteristics[CharacteristicIndex].Descriptors[
            DescriptorIndex]);
  end;
end;

procedure NativeScanStarted(AAdapter: TSimpleBleAdapter;
  AUserData: Pointer); cdecl;
var
  Allowed: Boolean;
  Driver: TLazBleNativeSimpleBleDriver;
begin
  if AUserData = nil then
    Exit;
  Driver := TLazBleNativeSimpleBleDriver(AUserData);
  Allowed := Driver.BeginCallback;
  try
    if Allowed then
      try
        Driver.ScanStarted;
      except
        { Exceptions must not cross the C callback boundary. }
      end;
  finally
    Driver.EndCallback;
  end;
end;

procedure NativeScanStopped(AAdapter: TSimpleBleAdapter;
  AUserData: Pointer); cdecl;
var
  Allowed: Boolean;
  Driver: TLazBleNativeSimpleBleDriver;
begin
  if AUserData = nil then
    Exit;
  Driver := TLazBleNativeSimpleBleDriver(AUserData);
  Allowed := Driver.BeginCallback;
  try
    if Allowed then
      try
        Driver.ScanStopped;
      except
        { Exceptions must not cross the C callback boundary. }
      end;
  finally
    Driver.EndCallback;
  end;
end;

procedure NativeScanResult(AAdapter: TSimpleBleAdapter;
  APeripheral: TSimpleBlePeripheral; AUserData: Pointer); cdecl;
var
  Allowed: Boolean;
  Driver: TLazBleNativeSimpleBleDriver;
  Handle: TSimpleBlePeripheral;
begin
  Handle := APeripheral;
  if AUserData = nil then
  begin
    if Handle <> nil then
      SimpleBlePeripheralReleaseHandle(Handle);
    Exit;
  end;
  Driver := TLazBleNativeSimpleBleDriver(AUserData);
  Allowed := Driver.BeginCallback;
  try
    if Allowed then
      try
        Driver.ScanResult(Handle);
      except
        { Exceptions must not cross the C callback boundary. }
      end;
  finally
    try
      if Handle <> nil then
        SimpleBlePeripheralReleaseHandle(Handle);
    finally
      Driver.EndCallback;
    end;
  end;
end;

procedure NativePeripheralDisconnected(APeripheral: TSimpleBlePeripheral;
  AUserData: Pointer); cdecl;
var
  Allowed: Boolean;
  Driver: TLazBleNativeSimpleBleDriver;
  Entry: TSimpleBlePeripheralEntry;
begin
  if AUserData = nil then
    Exit;
  Entry := TSimpleBlePeripheralEntry(AUserData);
  Driver := Entry.Owner;
  Allowed := Driver.BeginCallback;
  try
    if Allowed then
      try
        Driver.PeripheralDisconnected(Entry);
      except
        { Exceptions must not cross the C callback boundary. }
      end;
  finally
    Driver.EndCallback;
  end;
end;

procedure NativeNotification(APeripheral: TSimpleBlePeripheral;
  AService: TSimpleBleUuid; ACharacteristic: TSimpleBleUuid; AData: PByte;
  ADataLength: NativeUInt; AUserData: Pointer); cdecl;
var
  Allowed: Boolean;
  Driver: TLazBleNativeSimpleBleDriver;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  if AUserData = nil then
    Exit;
  Subscription := TSimpleBleSubscriptionEntry(AUserData);
  Driver := Subscription.Owner;
  Allowed := Driver.BeginCallback;
  try
    if Allowed then
      try
        Driver.NotificationReceived(Subscription, AData, ADataLength);
      except
        { Exceptions must not cross the C callback boundary. }
      end;
  finally
    Driver.EndCallback;
  end;
end;

constructor TLazBleNativeSimpleBleDriver.Create;
begin
  inherited Create;
  FScanWaitEvent := TEvent.Create(nil, True, False, '');
  FCallbackLock := TCriticalSection.Create;
  FCallbacksIdle := TEvent.Create(nil, True, True, '');
  FPeripherals := TObjectList.Create(True);
  { Retain inactive callback userdata until all native callbacks are drained
    during Close. }
  FSubscriptions := TObjectList.Create(True);
end;

destructor TLazBleNativeSimpleBleDriver.Destroy;
begin
  Close;
  FSubscriptions.Free;
  FPeripherals.Free;
  FCallbacksIdle.Free;
  FCallbackLock.Free;
  FScanWaitEvent.Free;
  inherited Destroy;
end;

function TLazBleNativeSimpleBleDriver.BeginCallback: Boolean;
begin
  FCallbackLock.Enter;
  try
    Result := not FClosing;
    Inc(FActiveCallbacks);
    FCallbacksIdle.ResetEvent;
  finally
    FCallbackLock.Leave;
  end;
end;

procedure TLazBleNativeSimpleBleDriver.EndCallback;
begin
  FCallbackLock.Enter;
  try
    Dec(FActiveCallbacks);
    if FActiveCallbacks = 0 then
      FCallbacksIdle.SetEvent;
  finally
    FCallbackLock.Leave;
  end;
end;

function TLazBleNativeSimpleBleDriver.ScanCallbacksActive: Boolean;
begin
  FCallbackLock.Enter;
  try
    Result := FScanCallbacksActive and not FClosing;
  finally
    FCallbackLock.Leave;
  end;
end;

procedure TLazBleNativeSimpleBleDriver.SetScanCallbacksActive(
  const AActive: Boolean);
begin
  FCallbackLock.Enter;
  try
    FScanCallbacksActive := AActive;
  finally
    FCallbackLock.Leave;
  end;
end;

procedure TLazBleNativeSimpleBleDriver.ClearScanCallbacks;
begin
  SetScanCallbacksActive(False);
  if FAdapter <> nil then
  begin
    SimpleBleAdapterSetCallbackOnScanStart(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanStop(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanFound(FAdapter, nil, nil);
    SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter, nil, nil);
  end;
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
  const ARequestedId: string; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  Adapter: TSimpleBleAdapter;
  AdapterAddress: string;
  AdapterCount: NativeUInt;
  AdapterIdentifier: string;
  AdapterIndex: NativeUInt;
  NativeError: TSimpleBleError;
begin
  AErrorCode := 0;
  AErrorMessage := '';
  if FAdapter <> nil then
  begin
    Result := (ARequestedId = '') or SameText(ARequestedId, FAdapterId);
    if not Result then
    begin
      AErrorCode := LazBleErrorAdapterAlreadyActive;
      AErrorMessage := 'A different BLE adapter is already active: ' +
        FAdapterId;
    end;
    Exit;
  end;

  NativeError := nil;
  AdapterCount := SimpleBleAdapterGetCount(NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not enumerate BLE adapters') then
    Exit(False);
  if AdapterCount = 0 then
  begin
    AErrorCode := LazBleErrorNoAdapter;
    AErrorMessage := 'No BLE adapter was found';
    Exit(False);
  end;

  for AdapterIndex := 0 to AdapterCount - 1 do
  begin
    NativeError := nil;
    Adapter := SimpleBleAdapterGetHandle(AdapterIndex, NativeError);
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'Could not open BLE adapter') then
    begin
      if Adapter <> nil then
        SimpleBleAdapterReleaseHandle(Adapter);
      Exit(False);
    end;
    if Adapter = nil then
      Continue;
    try
      NativeError := nil;
      AdapterIdentifier := CopyAndFreeNativeString(
        SimpleBleAdapterIdentifier(Adapter, NativeError));
      if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'Could not read BLE adapter identifier') then
        Exit(False);
      NativeError := nil;
      AdapterAddress := CopyAndFreeNativeString(
        SimpleBleAdapterAddress(Adapter, NativeError));
      if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'Could not read BLE adapter address') then
        Exit(False);
      if (ARequestedId = '') or SameText(ARequestedId, AdapterIdentifier) or
        SameText(ARequestedId, AdapterAddress) then
      begin
        FAdapter := Adapter;
        Adapter := nil;
        if AdapterIdentifier <> '' then
          FAdapterId := AdapterIdentifier
        else
          FAdapterId := AdapterAddress;
        AErrorMessage := '';
        Exit(True);
      end;
    finally
      if Adapter <> nil then
        SimpleBleAdapterReleaseHandle(Adapter);
    end;
  end;

  AErrorCode := LazBleErrorAdapterNotFound;
  AErrorMessage := 'BLE adapter was not found: ' + ARequestedId;
  Result := False;
end;

procedure TLazBleNativeSimpleBleDriver.ScanStarted;
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not ScanCallbacksActive or
    (FCurrentCommandKind <> lbckStartScan) or
    not Assigned(FEventSink) then
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
  if not ScanCallbacksActive or
    (FCurrentCommandKind <> lbckStartScan) or
    not Assigned(FEventSink) then
    Exit;
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekScanStopped;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.AdapterId := FAdapterId;
  FEventSink.Emit(BackendEvent);
end;

procedure TLazBleNativeSimpleBleDriver.ScanResult(
  var APeripheral: TSimpleBlePeripheral);
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  Rssi: SmallInt;
  NativeError: TSimpleBleError;
  ErrorCode: Integer;
  ErrorMessage: string;
  Stored: Boolean;
begin
  if (APeripheral = nil) or not ScanCallbacksActive then
    Exit;
  NativeError := nil;
  Rssi := SimpleBlePeripheralRssi(APeripheral, NativeError);
  if not ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
    'Could not read BLE signal strength') then
    Exit;
  try
    Stored := StorePeripheral(APeripheral, Entry, ErrorCode, ErrorMessage,
      FTargetScanDeviceId);
  finally
    APeripheral := nil; { StorePeripheral retains or releases the handle. }
  end;
  if not Stored then
    Exit;

  if (FTargetScanDeviceId <> '') and
    SameText(Entry.DeviceId, FTargetScanDeviceId) then
    FScanWaitEvent.SetEvent;

  if (FCurrentCommandKind = lbckStartScan) and Assigned(FEventSink) then
  begin
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekScanResult;
    BackendEvent.OperationId := FOperationId;
    BackendEvent.AdapterId := FAdapterId;
    BackendEvent.DeviceId := Entry.DeviceId;
    BackendEvent.DeviceName := Entry.DeviceName;
    BackendEvent.Rssi := Rssi;
    FEventSink.Emit(BackendEvent);
  end;
end;

procedure TLazBleNativeSimpleBleDriver.PeripheralDisconnected(
  const AEntry: TSimpleBlePeripheralEntry);
var
  BackendEvent: TLazBleBackendEvent;
  Index: Integer;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  if not Assigned(AEntry) then
    Exit;
  FCallbackLock.Enter;
  try
    if AEntry.DisconnectNotified then
      Exit;
    for Index := 0 to FSubscriptions.Count - 1 do
    begin
      Subscription := TSimpleBleSubscriptionEntry(FSubscriptions[Index]);
      if Subscription.Peripheral = AEntry then
        InterlockedExchange(Subscription.Active, 0);
    end;
    if not Assigned(FEventSink) or FClosing then
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
    AEntry.DisconnectNotified := True;
    FEventSink.Emit(BackendEvent);
  finally
    FCallbackLock.Leave;
  end;
end;

procedure TLazBleNativeSimpleBleDriver.NotificationReceived(
  const ASubscription: TSimpleBleSubscriptionEntry; const AData: PByte;
  const ADataLength: NativeUInt);
var
  BackendEvent: TLazBleBackendEvent;
begin
  if not Assigned(ASubscription) then
    Exit;
  FCallbackLock.Enter;
  try
    if not Assigned(FEventSink) or FClosing or
      (InterlockedCompareExchange(ASubscription.Active, 0, 0) = 0) or
      ((ADataLength > 0) and (AData = nil)) or
      (ADataLength > NativeUInt(High(SizeInt))) then
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
    if ADataLength > 0 then
      Move(AData^, BackendEvent.Value[0], ADataLength);
    FEventSink.Emit(BackendEvent);
  finally
    FCallbackLock.Leave;
  end;
end;

function TLazBleNativeSimpleBleDriver.FindPeripheral(
  const ADeviceId: string): TSimpleBlePeripheralEntry;
begin
  FCallbackLock.Enter;
  try
    Result := FindPeripheralLocked(ADeviceId);
  finally
    FCallbackLock.Leave;
  end;
end;

function TLazBleNativeSimpleBleDriver.FindPeripheralLocked(
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

function TLazBleNativeSimpleBleDriver.StorePeripheral(
  const APeripheral: TSimpleBlePeripheral;
  out AEntry: TSimpleBlePeripheralEntry;
  out AErrorCode: Integer; out AErrorMessage: string;
  const AExpectedDeviceId: string): Boolean;
var
  DeviceId: string;
  DeviceName: string;
  KeepHandle: Boolean;
  NativeError: TSimpleBleError;
begin
  AEntry := nil;
  AErrorCode := 0;
  AErrorMessage := '';
  Result := False;
  if APeripheral = nil then
    Exit;

  KeepHandle := False;
  try
    NativeError := nil;
    DeviceId := CopyAndFreeNativeString(
      SimpleBlePeripheralAddress(APeripheral, NativeError));
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'Could not read BLE device address') then
      Exit;
    if (DeviceId = '') or ((AExpectedDeviceId <> '') and
      not SameText(DeviceId, AExpectedDeviceId)) then
      Exit;
    NativeError := nil;
    DeviceName := CopyAndFreeNativeString(
      SimpleBlePeripheralIdentifier(APeripheral, NativeError));
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'Could not read BLE device identifier') then
      Exit;
    FCallbackLock.Enter;
    try
      AEntry := FindPeripheralLocked(DeviceId);
      if not Assigned(AEntry) then
      begin
        AEntry := TSimpleBlePeripheralEntry.Create;
        AEntry.Owner := Self;
        AEntry.Handle := APeripheral;
        AEntry.DeviceId := DeviceId;
        AEntry.DeviceName := DeviceName;
        FPeripherals.Add(AEntry);
        KeepHandle := True;
      end
      else if DeviceName <> '' then
        AEntry.DeviceName := DeviceName;
    finally
      FCallbackLock.Leave;
    end;
    Result := True;
  finally
    if not KeepHandle then
      SimpleBlePeripheralReleaseHandle(APeripheral);
  end;
end;

function TLazBleNativeSimpleBleDriver.FindConnectedPeripheral(
  const ADeviceId: string; out AEntry: TSimpleBlePeripheralEntry;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
var
  Count: NativeUInt;
  Index: NativeUInt;
  Peripheral: TSimpleBlePeripheral;
  StoredEntry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleError;
begin
  AEntry := nil;
  AErrorCode := 0;
  AErrorMessage := '';
  NativeError := nil;
  Count := SimpleBleAdapterGetConnectedPeripheralsCount(FAdapter, NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not enumerate connected BLE devices') then
    Exit(False);
  if Count > 0 then
    for Index := 0 to Count - 1 do
    begin
      NativeError := nil;
      Peripheral := SimpleBleAdapterGetConnectedPeripheralsHandle(FAdapter,
        Index, NativeError);
      if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'Could not open connected BLE device') then
      begin
        if Peripheral <> nil then
          SimpleBlePeripheralReleaseHandle(Peripheral);
        Exit(False);
      end;
      if not StorePeripheral(Peripheral, StoredEntry, AErrorCode,
        AErrorMessage, ADeviceId) then
      begin
        if AErrorMessage <> '' then
          Exit(False);
        Continue;
      end;
      if SameText(StoredEntry.DeviceId, ADeviceId) then
      begin
        AEntry := StoredEntry;
        Exit(True);
      end;
    end;
  Result := False;
end;

function TLazBleNativeSimpleBleDriver.FindPairedPeripheral(
  const ADeviceId: string; out AEntry: TSimpleBlePeripheralEntry;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
var
  Count: NativeUInt;
  Index: NativeUInt;
  Peripheral: TSimpleBlePeripheral;
  StoredEntry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleError;
begin
  AEntry := nil;
  AErrorCode := 0;
  AErrorMessage := '';
  NativeError := nil;
  Count := SimpleBleAdapterGetPairedPeripheralsCount(FAdapter, NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not enumerate paired BLE devices') then
    Exit(False);
  if Count > 0 then
    for Index := 0 to Count - 1 do
    begin
      NativeError := nil;
      Peripheral := SimpleBleAdapterGetPairedPeripheralsHandle(FAdapter,
        Index, NativeError);
      if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'Could not open paired BLE device') then
      begin
        if Peripheral <> nil then
          SimpleBlePeripheralReleaseHandle(Peripheral);
        Exit(False);
      end;
      if not StorePeripheral(Peripheral, StoredEntry, AErrorCode,
        AErrorMessage, ADeviceId) then
      begin
        if AErrorMessage <> '' then
          Exit(False);
        Continue;
      end;
      if SameText(StoredEntry.DeviceId, ADeviceId) then
      begin
        AEntry := StoredEntry;
        Exit(True);
      end;
    end;
  Result := False;
end;

function TLazBleNativeSimpleBleDriver.ScanForPeripheral(
  const ADeviceId: string; out AEntry: TSimpleBlePeripheralEntry;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
var
  NativeError: TSimpleBleError;
  Stopped: Boolean;
begin
  AEntry := nil;
  AErrorCode := 0;
  AErrorMessage := '';
  FScanWaitEvent.ResetEvent;
  FTargetScanDeviceId := ADeviceId;
  SetScanCallbacksActive(True);
  try
    SimpleBleAdapterSetCallbackOnScanFound(FAdapter, @NativeScanResult, Self);
    SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter, @NativeScanResult, Self);
    NativeError := nil;
    SimpleBleAdapterScanStart(FAdapter, NativeError);
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'Could not start SimpleBLE device discovery') then
      Exit(False);

    try
      FScanWaitEvent.WaitFor(DefaultSimpleBlePeripheralDiscoveryTimeoutMs);
    finally
      NativeError := nil;
      SimpleBleAdapterScanStop(FAdapter, NativeError);
      Stopped := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'Could not stop SimpleBLE device discovery');
    end;
    if not Stopped then
      Exit(False);
    AEntry := FindPeripheral(ADeviceId);
    Result := Assigned(AEntry);
    if not Result then
    begin
      AErrorCode := LazBleErrorDeviceNotFound;
      AErrorMessage := 'BLE device was not found: ' + ADeviceId;
    end;
  finally
    ClearScanCallbacks;
    FCallbacksIdle.WaitFor(High(Cardinal));
    FTargetScanDeviceId := '';
  end;
end;

function TLazBleNativeSimpleBleDriver.ResolvePeripheral(
  const ADeviceId: string; out AEntry: TSimpleBlePeripheralEntry;
  out AErrorCode: Integer; out AErrorMessage: string): Boolean;
begin
  AEntry := FindPeripheral(ADeviceId);
  if Assigned(AEntry) then
    Exit(True);
  if not SelectAdapter('', AErrorCode, AErrorMessage) then
    Exit(False);
  if FindConnectedPeripheral(ADeviceId, AEntry, AErrorCode,
    AErrorMessage) then
    Exit(True);
  if AErrorMessage <> '' then
    Exit(False);
  if FindPairedPeripheral(ADeviceId, AEntry, AErrorCode,
    AErrorMessage) then
    Exit(True);
  if AErrorMessage <> '' then
    Exit(False);
  Result := ScanForPeripheral(ADeviceId, AEntry, AErrorCode, AErrorMessage);
end;

function TLazBleNativeSimpleBleDriver.FindSubscription(
  const ASubscriptionId: TBleSubscriptionId): TSimpleBleSubscriptionEntry;
var
  Index: Integer;
begin
  for Index := 0 to FSubscriptions.Count - 1 do
  begin
    Result := TSimpleBleSubscriptionEntry(FSubscriptions[Index]);
    if (Result.SubscriptionId = ASubscriptionId) and
      (InterlockedCompareExchange(Result.Active, 0, 0) <> 0) then
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
  ErrorCode: Integer;
  ErrorMessage: string;
  Index: Integer;
  NativeError: TSimpleBleError;
  ScanActive: Boolean;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  FOperationId := InvalidBleOperationId;
  FCallbackLock.Enter;
  try
    FClosing := True;
    FScanCallbacksActive := False;
  finally
    FCallbackLock.Leave;
  end;
  FScanWaitEvent.SetEvent;
  if FLoaded and (FAdapter <> nil) then
  begin
    ClearScanCallbacks;
    NativeError := nil;
    ScanActive := SimpleBleAdapterScanIsActive(FAdapter, NativeError);
    if ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
      'Could not check scan during shutdown') and ScanActive then
    begin
      NativeError := nil;
      SimpleBleAdapterScanStop(FAdapter, NativeError);
      ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
        'Could not stop scan during shutdown');
    end;
  end;
  FCallbacksIdle.WaitFor(High(Cardinal));

  for Index := 0 to FSubscriptions.Count - 1 do
  begin
    Subscription := TSimpleBleSubscriptionEntry(FSubscriptions[Index]);
    if InterlockedExchange(Subscription.Active, 0) = 0 then
      Continue;
    if FLoaded and (Subscription.Peripheral.Handle <> nil) and
      TryCreateNativeUuid(Subscription.ServiceUuid, ServiceUuid) and
      TryCreateNativeUuid(Subscription.CharacteristicUuid,
        CharacteristicUuid) then
    begin
      NativeError := nil;
      SimpleBlePeripheralUnsubscribe(Subscription.Peripheral.Handle,
        ServiceUuid, CharacteristicUuid, NativeError);
      ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
        'Could not unsubscribe during shutdown');
    end;
  end;
  for Index := 0 to FPeripherals.Count - 1 do
  begin
    Entry := TSimpleBlePeripheralEntry(FPeripherals[Index]);
    if FLoaded and (Entry.Handle <> nil) then
      SimpleBlePeripheralSetCallbackOnDisconnected(Entry.Handle, nil, nil);
  end;
  FCallbacksIdle.WaitFor(High(Cardinal));
  FSubscriptions.Clear;

  while FPeripherals.Count > 0 do
  begin
    Entry := TSimpleBlePeripheralEntry(FPeripherals[FPeripherals.Count - 1]);
    if FLoaded and (Entry.Handle <> nil) then
    begin
      NativeError := nil;
      Connected := SimpleBlePeripheralIsConnected(Entry.Handle, NativeError);
      if ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
        'Could not check connection during shutdown') and Connected then
      begin
        NativeError := nil;
        SimpleBlePeripheralDisconnect(Entry.Handle, NativeError);
        ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
          'Could not disconnect during shutdown');
      end;
      SimpleBlePeripheralReleaseHandle(Entry.Handle);
      Entry.Handle := nil;
    end;
    FPeripherals.Delete(FPeripherals.Count - 1);
  end;
  if FAdapter <> nil then
  begin
    SimpleBleAdapterReleaseHandle(FAdapter);
    FAdapter := nil;
  end;
  FAdapterId := '';
  FEventSink := nil;
  if FLoaded then
  begin
    {$IFDEF LAZBLE_NATIVE_TESTS}
    if not FInjectedForTests then
    {$ENDIF}
    SimpleBleUnloadLibrary;
    FLoaded := False;
  end;
end;

{$IFDEF LAZBLE_NATIVE_TESTS}
function CreateNativeSimpleBleDriverForTests: ILazBleSimpleBleDriver;
var
  Driver: TLazBleNativeSimpleBleDriver;
begin
  Driver := TLazBleNativeSimpleBleDriver.Create;
  Driver.FLoaded := True;
  Driver.FInjectedForTests := True;
  Result := Driver;
end;
{$ENDIF}

function TLazBleNativeSimpleBleDriver.ExecuteScan(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  NativeError: TSimpleBleError;
  Stopped: Boolean;
  TimeoutMs: Integer;
begin
  Result := False;
  if not SelectAdapter(ACommand.AdapterId, AErrorCode,
    AErrorMessage) then
    Exit;
  SetScanCallbacksActive(True);
  try
    SimpleBleAdapterSetCallbackOnScanStart(FAdapter, @NativeScanStarted, Self);
    SimpleBleAdapterSetCallbackOnScanStop(FAdapter, @NativeScanStopped, Self);
    SimpleBleAdapterSetCallbackOnScanFound(FAdapter, @NativeScanResult, Self);
    SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter, @NativeScanResult, Self);

    if ACommand.TimeoutMs > Cardinal(High(Integer)) then
      TimeoutMs := High(Integer)
    else
      TimeoutMs := ACommand.TimeoutMs;
    FScanWaitEvent.ResetEvent;
    NativeError := nil;
    SimpleBleAdapterScanStart(FAdapter, NativeError);
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'SimpleBLE scan start failed') then
      Exit(False);
    try
      FScanWaitEvent.WaitFor(TimeoutMs);
    finally
      NativeError := nil;
      SimpleBleAdapterScanStop(FAdapter, NativeError);
      Stopped := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
        'SimpleBLE scan stop failed');
    end;
    Result := Stopped;
  finally
    ClearScanCallbacks;
    FCallbacksIdle.WaitFor(High(Cardinal));
  end;
end;

function TLazBleNativeSimpleBleDriver.ExecuteAvailability(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  AdapterError: string;
  BackendEvent: TLazBleBackendEvent;
  Enabled: Boolean;
  NativeError: TSimpleBleError;
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
  BackendEvent.Available := SelectAdapter(ACommand.AdapterId,
    AErrorCode, AdapterError);
  if BackendEvent.Available then
  begin
    NativeError := nil;
    Enabled := SimpleBleAdapterIsBluetoothEnabled(NativeError);
    if not ConsumeNativeError(NativeError, AErrorCode, AdapterError,
      'Could not check Bluetooth availability') then
      BackendEvent.Available := False
    else if not Enabled then
    begin
      BackendEvent.Available := False;
      AErrorCode := LazBleErrorBluetoothDisabled;
      AdapterError := 'Bluetooth is disabled';
    end;
  end;
  if BackendEvent.Available then
    BackendEvent.AdapterId := FAdapterId
  else
    BackendEvent.AdapterId := ACommand.AdapterId;
  FEventSink.Emit(BackendEvent);
  AErrorMessage := AdapterError;
  Result := BackendEvent.Available;
end;

function TLazBleNativeSimpleBleDriver.ExecuteConnect(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Connected: Boolean;
  Entry: TSimpleBlePeripheralEntry;
  NativeError: TSimpleBleError;
begin
  if not ResolvePeripheral(ACommand.DeviceId, Entry, AErrorCode,
    AErrorMessage) then
    Exit(False);
  SimpleBlePeripheralSetCallbackOnDisconnected(Entry.Handle,
    @NativePeripheralDisconnected, Entry);
  NativeError := nil;
  Connected := SimpleBlePeripheralIsConnected(Entry.Handle, NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not check BLE connection') then
    Exit(False);
  if not Connected then
  begin
    NativeError := nil;
    SimpleBlePeripheralConnect(Entry.Handle, NativeError);
    if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'SimpleBLE connect failed') then
      Exit(False);
  end;
  NativeError := nil;
  Connected := SimpleBlePeripheralIsConnected(Entry.Handle, NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not verify BLE connection') then
    Exit(False);
  if not Connected then
  begin
    AErrorCode := LazBleErrorDeviceDisconnected;
    AErrorMessage := 'BLE device disconnected during connect';
    Exit(False);
  end;
  Result := True;
  FCallbackLock.Enter;
  try
    Entry.Generation := ACommand.Generation;
    Entry.DisconnectNotified := False;
  finally
    FCallbackLock.Leave;
  end;
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
  CharacteristicUuid: TSimpleBleUuid;
  Entry: TSimpleBlePeripheralEntry;
  ErrorCode: Integer;
  ErrorMessage: string;
  Index: Integer;
  NativeError: TSimpleBleError;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorCode := LazBleErrorDeviceNotKnown;
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  for Index := 0 to FSubscriptions.Count - 1 do
  begin
    Subscription := TSimpleBleSubscriptionEntry(FSubscriptions[Index]);
    if (Subscription.Peripheral <> Entry) or
      (InterlockedExchange(Subscription.Active, 0) = 0) then
      Continue;
    if TryCreateNativeUuid(Subscription.ServiceUuid, ServiceUuid) and
      TryCreateNativeUuid(Subscription.CharacteristicUuid,
        CharacteristicUuid) then
    begin
      NativeError := nil;
      SimpleBlePeripheralUnsubscribe(Entry.Handle, ServiceUuid,
        CharacteristicUuid, NativeError);
      ConsumeNativeError(NativeError, ErrorCode, ErrorMessage,
        'Could not unsubscribe before disconnect');
    end;
  end;
  FCallbacksIdle.WaitFor(High(Cardinal));
  FCallbackLock.Enter;
  try
    Entry.DisconnectRequested := True;
  finally
    FCallbackLock.Leave;
  end;
  NativeError := nil;
  SimpleBlePeripheralDisconnect(Entry.Handle, NativeError);
  Result := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'SimpleBLE disconnect failed');
  if not Result then
  begin
    FCallbackLock.Enter;
    try
      Entry.DisconnectRequested := False;
    finally
      FCallbackLock.Leave;
    end;
    Exit;
  end;
  FCallbackLock.Enter;
  try
    if Entry.DisconnectRequested and not Entry.DisconnectNotified then
    begin
      Entry.DisconnectRequested := False;
      Entry.DisconnectNotified := True;
      BackendEvent := Default(TLazBleBackendEvent);
      BackendEvent.Kind := lbekDisconnected;
      BackendEvent.OperationId := FOperationId;
      BackendEvent.Generation := Entry.Generation;
      BackendEvent.DeviceId := Entry.DeviceId;
      FEventSink.Emit(BackendEvent);
    end;
  finally
    FCallbackLock.Leave;
  end;
end;

function TLazBleNativeSimpleBleDriver.ExecuteDiscovery(
  const ACommand: TLazBleBackendCommand; out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
var
  BackendEvent: TLazBleBackendEvent;
  Entry: TSimpleBlePeripheralEntry;
  Index: NativeUInt;
  NativeError: TSimpleBleError;
  Service: TSimpleBleService;
  ServiceCount: NativeUInt;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorCode := LazBleErrorDeviceNotKnown;
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  NativeError := nil;
  ServiceCount := SimpleBlePeripheralServicesCount(Entry.Handle,
    NativeError);
  if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'Could not count BLE services') then
    Exit(False);
  if ServiceCount > NativeUInt(High(SizeInt)) then
  begin
    AErrorCode := LazBleErrorNativeDataTooLarge;
    AErrorMessage := 'SimpleBLE returned too many services';
    Exit(False);
  end;
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
      NativeError := nil;
      try
        SimpleBlePeripheralServicesGet(Entry.Handle, Index, Service,
          NativeError);
        if not ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
          'SimpleBLE service discovery failed') then
          Exit(False);
        try
          CopyNativeService(Service, BackendEvent.Services[Index]);
        except
          on E: ESimpleBleInvalidNativeData do
          begin
            AErrorCode := LazBleErrorInvalidNativeData;
            AErrorMessage := 'Invalid SimpleBLE service data: ' + E.Message;
            Exit(False);
          end;
        end;
      finally
        if NativeError <> nil then
          SimpleBleErrorRelease(NativeError);
        SimpleBleServiceRelease(Service);
      end;
    end;
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
  NativeError: TSimpleBleError;
  ServiceUuid: TSimpleBleUuid;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorCode := LazBleErrorDeviceNotKnown;
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorCode := LazBleErrorInvalidGattUuid;
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  Data := nil;
  DataLength := 0;
  try
    NativeError := nil;
    Data := SimpleBlePeripheralRead(Entry.Handle, ServiceUuid,
      CharacteristicUuid, DataLength, NativeError);
    Result := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
      'SimpleBLE read failed');
    if not Result then
      Exit;
    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekReadResult;
    BackendEvent.OperationId := FOperationId;
    BackendEvent.Generation := Entry.Generation;
    BackendEvent.DeviceId := Entry.DeviceId;
    BackendEvent.ServiceUuid := ACommand.ServiceUuid;
    BackendEvent.CharacteristicUuid := ACommand.CharacteristicUuid;
    try
      BackendEvent.Value := SimpleBleCopyBufferAndFree(Data, DataLength);
    except
      on E: ESimpleBleInvalidNativeData do
      begin
        AErrorCode := LazBleErrorInvalidNativeData;
        AErrorMessage := 'Invalid SimpleBLE read data: ' + E.Message;
        Exit(False);
      end;
    end;
    FEventSink.Emit(BackendEvent);
  finally
    if NativeError <> nil then
      SimpleBleErrorRelease(NativeError);
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
  NativeError: TSimpleBleError;
  ServiceUuid: TSimpleBleUuid;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorCode := LazBleErrorDeviceNotKnown;
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorCode := LazBleErrorInvalidGattUuid;
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  if Length(ACommand.Value) = 0 then
    Data := nil
  else
    Data := @ACommand.Value[0];
  NativeError := nil;
  if ACommand.WriteMode = lbwmCommand then
    SimpleBlePeripheralWriteCommand(Entry.Handle,
      ServiceUuid, CharacteristicUuid, Data, Length(ACommand.Value),
      NativeError)
  else
    SimpleBlePeripheralWriteRequest(Entry.Handle,
      ServiceUuid, CharacteristicUuid, Data, Length(ACommand.Value),
      NativeError);
  Result := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'SimpleBLE write failed');
  if not Result then
    Exit;
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
  NativeError: TSimpleBleError;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  Entry := FindPeripheral(ACommand.DeviceId);
  if not Assigned(Entry) then
  begin
    AErrorCode := LazBleErrorDeviceNotKnown;
    AErrorMessage := 'BLE device is not known: ' + ACommand.DeviceId;
    Exit(False);
  end;
  if not TryCreateNativeUuid(ACommand.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(ACommand.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorCode := LazBleErrorInvalidGattUuid;
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
  Subscription.Active := 1;
  FCallbackLock.Enter;
  try
    FSubscriptions.Add(Subscription);
  finally
    FCallbackLock.Leave;
  end;
  NativeError := nil;
  SimpleBlePeripheralNotify(Entry.Handle, ServiceUuid,
    CharacteristicUuid, @NativeNotification, Subscription, NativeError);
  Result := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'SimpleBLE subscribe failed');
  if not Result then
  begin
    InterlockedExchange(Subscription.Active, 0);
    NativeError := nil;
    SimpleBlePeripheralUnsubscribe(Entry.Handle, ServiceUuid,
      CharacteristicUuid, NativeError);
    if NativeError <> nil then
      SimpleBleErrorRelease(NativeError);
    FCallbacksIdle.WaitFor(High(Cardinal));
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
  NativeError: TSimpleBleError;
  ServiceUuid: TSimpleBleUuid;
  Subscription: TSimpleBleSubscriptionEntry;
begin
  Subscription := FindSubscription(ACommand.SubscriptionId);
  if not Assigned(Subscription) then
  begin
    AErrorCode := LazBleErrorSubscriptionNotKnown;
    AErrorMessage := 'BLE subscription is not known';
    Exit(False);
  end;
  if not TryCreateNativeUuid(Subscription.ServiceUuid, ServiceUuid) or
    not TryCreateNativeUuid(Subscription.CharacteristicUuid,
      CharacteristicUuid) then
  begin
    AErrorCode := LazBleErrorInvalidGattUuid;
    AErrorMessage := 'Invalid GATT UUID';
    Exit(False);
  end;
  InterlockedExchange(Subscription.Active, 0);
  NativeError := nil;
  SimpleBlePeripheralUnsubscribe(
    Subscription.Peripheral.Handle, ServiceUuid, CharacteristicUuid,
    NativeError);
  Result := ConsumeNativeError(NativeError, AErrorCode, AErrorMessage,
    'SimpleBLE unsubscribe failed');
  if not Result then
  begin
    InterlockedExchange(Subscription.Active, 1);
    Exit;
  end;
  FCallbacksIdle.WaitFor(High(Cardinal));
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekUnsubscribed;
  BackendEvent.OperationId := FOperationId;
  BackendEvent.SubscriptionId := Subscription.SubscriptionId;
  BackendEvent.Generation := Subscription.Peripheral.Generation;
  BackendEvent.DeviceId := Subscription.Peripheral.DeviceId;
  BackendEvent.ServiceUuid := Subscription.ServiceUuid;
  BackendEvent.CharacteristicUuid := Subscription.CharacteristicUuid;
  FEventSink.Emit(BackendEvent);
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
  if not Assigned(FEventSink) then
    FEventSink := AEventSink;
  FCurrentCommandKind := ACommand.Kind;
  try
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
        AErrorCode := LazBleErrorCommandNotImplemented;
        AErrorMessage := 'SimpleBLE backend command is not implemented';
        Result := False;
      end;
    end;
  finally
    FOperationId := InvalidBleOperationId;
  end;
end;

procedure TLazBleNativeSimpleBleDriver.CancelCurrent;
begin
  if FCurrentCommandKind in [lbckStartScan, lbckConnect] then
    FScanWaitEvent.SetEvent;
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

constructor TLazBleSimpleBleBackend.TEventWorker.Create(
  const ABackend: TLazBleSimpleBleBackend);
begin
  FBackend := ABackend;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TLazBleSimpleBleBackend.TEventWorker.Execute;
begin
  FBackend.EventWorkerExecute;
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
  FEventWorkEvent := RTLEventCreate;
  FDriver := ADriver;
  FOperations := TList.Create;
  FPendingOperations := TList.Create;
  FPendingEvents := TList.Create;
  DriverSink := TLazBleSimpleBleDriverSink.Create(Self);
  FDriverEventSink := DriverSink;
  FDriverEventSinkControl := DriverSink;
  FEventWorker := TEventWorker.Create(Self);
  FWorker := TBackendWorker.Create(Self);
end;

destructor TLazBleSimpleBleBackend.Destroy;
var
  Index: Integer;
begin
  BeginShutdown;
  FWorker.WaitFor;
  FWorker.Free;
  EnterCriticalSection(FLock);
  try
    FEventShutdownRequested := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FEventWorkEvent);
  FEventWorker.WaitFor;
  FEventWorker.Free;
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
  RTLEventDestroy(FEventWorkEvent);
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
    RTLEventSetEvent(FEventWorkEvent);
end;

procedure TLazBleSimpleBleBackend.QueueEvent(
  const AEvent: TLazBleBackendEvent);
var
  QueuedEvent: TQueuedEvent;
begin
  QueuedEvent := TQueuedEvent.Create;
  QueuedEvent.BackendEvent := AEvent;
  EnterCriticalSection(FLock);
  try
    FPendingEvents.Add(QueuedEvent);
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FEventWorkEvent);
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
  QueueEvent(BackendEvent);
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
  begin
    ErrorCode := LazBleErrorBackendUnavailable;
    ErrorMessage := OpenError;
  end;
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

    repeat
      Operation := PopOperation;
      if not Assigned(Operation) then
        Break;
      ProcessOperation(Operation);
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
      QueueEvent(BackendEvent);
      Exit;
    end;
  until False;
end;

procedure TLazBleSimpleBleBackend.EventWorkerExecute;
var
  ShouldStop: Boolean;
begin
  repeat
    RTLEventWaitFor(FEventWorkEvent);
    RTLEventResetEvent(FEventWorkEvent);
    DrainEvents;
    EnterCriticalSection(FLock);
    try
      ShouldStop := FEventShutdownRequested and
        (FPendingEvents.Count = 0);
    finally
      LeaveCriticalSection(FLock);
    end;
  until ShouldStop;
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
