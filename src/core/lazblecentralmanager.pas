unit LazBleCentralManager;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, LazBleTypes, LazBleBackend, LazBleGattSession;

type
  TLazBleCentralState = (lbcsIdle, lbcsScanning, lbcsShuttingDown, lbcsShutdown);
  TLazBleScanCompletedEvent = procedure(Sender: TObject;
    const AOutcome: TLazBleBackendEventKind; const AErrorCode: Integer;
    const AErrorMessage: string) of object;
  TLazBleCentralStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleCentralState) of object;
  TLazBleAvailabilityCompletedEvent = TLazBleScanCompletedEvent;
  TLazBleAvailabilityResultEvent = procedure(Sender: TObject;
    const AEvent: TLazBleBackendEvent) of object;

  TBleCentralManager = class;
  TLazBleManagerRequestKind = (lmrScan, lmrAvailability, lmrShutdown);

  TLazBleManagerRequest = class(TInterfacedObject, ILazBleRequestCompletion,
    ILazBleScanSink)
  private
    FManager: TBleCentralManager;
    FKind: TLazBleManagerRequestKind;
    FTarget: ILazBleRequestCompletion;
    FScan: ILazBleScanSink;
  public
    constructor Create(AManager: TBleCentralManager; AKind: TLazBleManagerRequestKind;
      const ATarget: ILazBleRequestCompletion; const AScan: ILazBleScanSink = nil);
    procedure Detach;
    procedure CompleteRequest(const AResult: TLazBleRequestResult);
    procedure ReceiveScanResult(const ADevice: TBleDeviceInfo);
  end;

  { Owns sessions and coordinates scan, availability and shutdown. }
  TBleCentralManager = class
  private
    FBackend: ILazBleBackend;
    FRequests: array[TLazBleManagerRequestKind] of ILazBleRequestCompletion;
    FRequestObjects: array[TLazBleManagerRequestKind] of TLazBleManagerRequest;
    FSessions: TList;
    FState: TLazBleCentralState;
    FScanOperationId, FAvailabilityOperationId, FShutdownOperationId: TBleOperationId;
    FShutdownFailed: Boolean;
    FShutdownErrorCode: Integer;
    FShutdownErrorMessage: string;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleScanCompletedEvent;
    FOnAvailabilityResult: TLazBleAvailabilityResultEvent;
    FOnAvailabilityCompleted: TLazBleAvailabilityCompletedEvent;
    FOnStateChanged: TLazBleCentralStateChangedEvent;
    procedure SetState(const AState: TLazBleCentralState);
    function SubmitCommand(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion = nil;
      const AValues: ILazBleValueSink = nil; const AScan: ILazBleScanSink = nil;
      const ALink: ILazBleLinkObserver = nil): TBleOperationId;
    procedure CancelOperation(const AOperationId: TBleOperationId);
    function NewRequest(AKind: TLazBleManagerRequestKind;
      const ATarget: ILazBleRequestCompletion;
      const AScan: ILazBleScanSink = nil): TLazBleManagerRequest;
    procedure RequestFinished(AKind: TLazBleManagerRequestKind;
      const AResult: TLazBleRequestResult);
  protected
    procedure DetachBackendEvents;
  public
    constructor Create(const ABackend: ILazBleBackend);
    destructor Destroy; override;
    function StartScan(const AAdapterId: string; const ATimeoutMs: Cardinal;
      const ACompletion: ILazBleRequestCompletion = nil;
      const AScan: ILazBleScanSink = nil): TBleOperationId;
    procedure CancelScan;
    function CheckAvailability(const AAdapterId: string;
      const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
    procedure CancelAvailabilityCheck;
    function CreateSession(const ADeviceId: string): TBleGattSession;
    function BeginShutdown(const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
    property ShutdownFailed: Boolean read FShutdownFailed;
    property ShutdownErrorCode: Integer read FShutdownErrorCode;
    property ShutdownErrorMessage: string read FShutdownErrorMessage;
    property State: TLazBleCentralState read FState;
    property OnScanResult: TLazBleScanResultEvent read FOnScanResult write FOnScanResult;
    property OnScanCompleted: TLazBleScanCompletedEvent read FOnScanCompleted write FOnScanCompleted;
    property OnAvailabilityResult: TLazBleAvailabilityResultEvent read FOnAvailabilityResult write FOnAvailabilityResult;
    property OnAvailabilityCompleted: TLazBleAvailabilityCompletedEvent read FOnAvailabilityCompleted write FOnAvailabilityCompleted;
    property OnStateChanged: TLazBleCentralStateChangedEvent read FOnStateChanged write FOnStateChanged;
  end;

implementation

type
  TBleGattSessionAccess = class(TBleGattSession)
  public
    constructor CreateInternal(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand; const ACancelOperation: TLazBleCancelOperation);
    procedure HandleShutdown;
    procedure PrepareShutdownInternal;
  end;

constructor TBleGattSessionAccess.CreateInternal(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand; const ACancelOperation: TLazBleCancelOperation);
begin inherited Create(ADeviceId, ASubmitCommand, ACancelOperation); end;
procedure TBleGattSessionAccess.HandleShutdown;
begin HandleBackendShutdown; end;
procedure TBleGattSessionAccess.PrepareShutdownInternal;
begin PrepareShutdown; end;

constructor TLazBleManagerRequest.Create(AManager: TBleCentralManager;
  AKind: TLazBleManagerRequestKind; const ATarget: ILazBleRequestCompletion;
  const AScan: ILazBleScanSink);
begin
  inherited Create;
  FManager := AManager; FKind := AKind; FTarget := ATarget; FScan := AScan;
end;

procedure TLazBleManagerRequest.Detach;
begin
  LazBleRequireMainThread;
  FManager := nil; FTarget := nil; FScan := nil;
end;

procedure TLazBleManagerRequest.CompleteRequest(const AResult: TLazBleRequestResult);
var Manager: TBleCentralManager; Target, KeepAlive: ILazBleRequestCompletion;
  R: TLazBleRequestResult;
begin
  LazBleRequireMainThread;
  KeepAlive := Self;
  Manager := FManager; Target := FTarget;
  if Manager = nil then Exit;
  Detach;
  R := AResult;
  if (FKind = lmrAvailability) and (R.Status = lbrsSucceeded) and
    not (R.Availability in [lbaAvailable, lbaUnavailable]) then
  begin
    R.Status := lbrsFailed; R.ErrorCode := 0;
    R.ErrorMessage := 'BLE backend did not report availability';
  end;
  try
    Manager.RequestFinished(FKind, R);
  finally
    if Target <> nil then Target.CompleteRequest(R);
  end;
end;

procedure TLazBleManagerRequest.ReceiveScanResult(const ADevice: TBleDeviceInfo);
var Sink: ILazBleScanSink;
begin
  LazBleRequireMainThread;
  if (FManager = nil) or (FManager.State <> lbcsScanning) then Exit;
  Sink := FScan;
  if Assigned(FManager.FOnScanResult) then
    FManager.FOnScanResult(FManager, ADevice.DeviceId, ADevice.DeviceName, ADevice.Rssi);
  if (FManager <> nil) and (FManager.State = lbcsScanning) and (Sink <> nil) then
    Sink.ReceiveScanResult(ADevice);
end;

constructor TBleCentralManager.Create(const ABackend: ILazBleBackend);
begin
  inherited Create;
  LazBleRequireMainThread;
  if ABackend = nil then raise EArgumentNilException.Create('ABackend');
  FBackend := ABackend; FSessions := TList.Create;
end;

destructor TBleCentralManager.Destroy;
var I: Integer;
begin
  DetachBackendEvents;
  if Assigned(FBackend) and (FState <> lbcsShutdown) then FBackend.BeginShutdown;
  for I := FSessions.Count - 1 downto 0 do TObject(FSessions[I]).Free;
  FSessions.Free;
  FBackend := nil;
  inherited Destroy;
end;

procedure TBleCentralManager.DetachBackendEvents;
var Kind: TLazBleManagerRequestKind;
begin
  LazBleRequireMainThread;
  for Kind in TLazBleManagerRequestKind do
  begin
    if FRequestObjects[Kind] <> nil then FRequestObjects[Kind].Detach;
    FRequests[Kind] := nil; FRequestObjects[Kind] := nil;
  end;
end;

procedure TBleCentralManager.SetState(const AState: TLazBleCentralState);
begin
  LazBleRequireMainThread;
  if FState = AState then Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then FOnStateChanged(Self, FState);
end;

function TBleCentralManager.NewRequest(AKind: TLazBleManagerRequestKind;
  const ATarget: ILazBleRequestCompletion; const AScan: ILazBleScanSink): TLazBleManagerRequest;
begin
  Result := TLazBleManagerRequest.Create(Self, AKind, ATarget, AScan);
  FRequestObjects[AKind] := Result;
  FRequests[AKind] := Result;
end;

function TBleCentralManager.SubmitCommand(const ACommand: TLazBleBackendCommand;
  const ACompletion: ILazBleRequestCompletion; const AValues: ILazBleValueSink;
  const AScan: ILazBleScanSink; const ALink: ILazBleLinkObserver): TBleOperationId;
begin
  LazBleRequireMainThread;
  if (FBackend = nil) or (FState in [lbcsShuttingDown, lbcsShutdown]) then
    Exit(InvalidBleOperationId);
  Result := FBackend.Submit(ACommand, ACompletion, AValues, AScan, ALink);
end;

procedure TBleCentralManager.CancelOperation(const AOperationId: TBleOperationId);
begin
  LazBleRequireMainThread;
  if Assigned(FBackend) and not (FState in [lbcsShuttingDown, lbcsShutdown]) then
    FBackend.Cancel(AOperationId);
end;

function TBleCentralManager.StartScan(const AAdapterId: string; const ATimeoutMs: Cardinal;
  const ACompletion: ILazBleRequestCompletion; const AScan: ILazBleScanSink): TBleOperationId;
var Command: TLazBleBackendCommand; Request: TLazBleManagerRequest;
begin
  LazBleRequireMainThread;
  if (FState <> lbcsIdle) or (FAvailabilityOperationId <> InvalidBleOperationId) then
    Exit(InvalidBleOperationId);
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckStartScan; Command.AdapterId := AAdapterId; Command.TimeoutMs := ATimeoutMs;
  Request := NewRequest(lmrScan, ACompletion, AScan);
  Result := SubmitCommand(Command, Request, nil, Request);
  if Result <> InvalidBleOperationId then
  begin
    FScanOperationId := Result; SetState(lbcsScanning);
  end
  else begin Request.Detach; FRequests[lmrScan] := nil; FRequestObjects[lmrScan] := nil; end;
end;

function TBleCentralManager.CheckAvailability(const AAdapterId: string;
  const ACompletion: ILazBleRequestCompletion): TBleOperationId;
var Command: TLazBleBackendCommand; Request: TLazBleManagerRequest;
begin
  LazBleRequireMainThread;
  if (FState <> lbcsIdle) or (FAvailabilityOperationId <> InvalidBleOperationId) then
    Exit(InvalidBleOperationId);
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckCheckAvailability; Command.AdapterId := AAdapterId;
  Request := NewRequest(lmrAvailability, ACompletion);
  Result := SubmitCommand(Command, Request);
  FAvailabilityOperationId := Result;
  if Result = InvalidBleOperationId then
  begin Request.Detach; FRequests[lmrAvailability] := nil; FRequestObjects[lmrAvailability] := nil; end;
end;

procedure TBleCentralManager.CancelScan;
begin LazBleRequireMainThread; CancelOperation(FScanOperationId); end;
procedure TBleCentralManager.CancelAvailabilityCheck;
begin LazBleRequireMainThread; CancelOperation(FAvailabilityOperationId); end;

function TBleCentralManager.CreateSession(const ADeviceId: string): TBleGattSession;
var I: Integer;
begin
  LazBleRequireMainThread;
  if FState in [lbcsShuttingDown, lbcsShutdown] then Exit(nil);
  for I := 0 to FSessions.Count - 1 do
    if TBleGattSession(FSessions[I]).DeviceId = ADeviceId then
      Exit(TBleGattSession(FSessions[I]));
  Result := TBleGattSessionAccess.CreateInternal(ADeviceId, @SubmitCommand, @CancelOperation);
  FSessions.Add(Result);
end;

function TBleCentralManager.BeginShutdown(const ACompletion: ILazBleRequestCompletion): TBleOperationId;
var I: Integer; Request: TLazBleManagerRequest;
begin
  LazBleRequireMainThread;
  if FState in [lbcsShuttingDown, lbcsShutdown] then Exit(FShutdownOperationId);
  SetState(lbcsShuttingDown);
  for I := 0 to FSessions.Count - 1 do TBleGattSessionAccess(FSessions[I]).PrepareShutdownInternal;
  Request := NewRequest(lmrShutdown, ACompletion);
  FShutdownOperationId := FBackend.BeginShutdown(Request);
  Result := FShutdownOperationId;
end;

procedure TBleCentralManager.RequestFinished(AKind: TLazBleManagerRequestKind;
  const AResult: TLazBleRequestResult);
var I: Integer; Outcome: TLazBleBackendEventKind; Event: TLazBleBackendEvent;
  Device: TBleDeviceInfo;
begin
  FRequests[AKind] := nil; FRequestObjects[AKind] := nil;
  case AResult.Status of
    lbrsSucceeded: Outcome := lbekOperationSucceeded;
    lbrsFailed: Outcome := lbekOperationFailed;
    lbrsCancelled: Outcome := lbekOperationCancelled;
  end;
  case AKind of
    lmrScan:
      begin
        FScanOperationId := InvalidBleOperationId;
        if FState = lbcsScanning then SetState(lbcsIdle);
        if not (FState in [lbcsShuttingDown, lbcsShutdown]) and Assigned(FOnScanResult) then
          for Device in AResult.ScanResults do
            FOnScanResult(Self, Device.DeviceId, Device.DeviceName, Device.Rssi);
        if Assigned(FOnScanCompleted) then
          FOnScanCompleted(Self, Outcome, AResult.ErrorCode, AResult.ErrorMessage);
      end;
    lmrAvailability:
      begin
        FAvailabilityOperationId := InvalidBleOperationId;
        if (AResult.Status = lbrsSucceeded) and Assigned(FOnAvailabilityResult) then
        begin
          Event := Default(TLazBleBackendEvent);
          Event.Kind := lbekAvailabilityResult;
          Event.Available := AResult.Availability = lbaAvailable;
          Event.BackendName := AResult.BackendName; Event.BackendVersion := AResult.BackendVersion;
          Event.AdapterId := AResult.AdapterId;
          FOnAvailabilityResult(Self, Event);
        end;
        if Assigned(FOnAvailabilityCompleted) then
          FOnAvailabilityCompleted(Self, Outcome, AResult.ErrorCode, AResult.ErrorMessage);
      end;
    lmrShutdown:
      begin
        FShutdownFailed := AResult.Status <> lbrsSucceeded;
        FShutdownErrorCode := AResult.ErrorCode; FShutdownErrorMessage := AResult.ErrorMessage;
        for I := 0 to FSessions.Count - 1 do TBleGattSessionAccess(FSessions[I]).HandleShutdown;
        DetachBackendEvents;
        SetState(lbcsShutdown);
      end;
  end;
end;

end.
