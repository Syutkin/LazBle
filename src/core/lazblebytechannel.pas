unit LazBleByteChannel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession;

type
  TLazBleByteChannelState = (
    lbchsDetached,
    lbchsSubscribing,
    lbchsReady,
    lbchsUnsubscribing,
    lbchsError
  );

  TLazBleByteChannelDataEvent = procedure(Sender: TObject;
    const AValue: TBytes) of object;

  { A writable characteristic paired with a notification characteristic in
    one GATT service. The caller retains the session for this object's life. }
  TBleByteChannel = class
  private
    FSession: TBleGattSession;
    FServiceUuid: string;
    FWriteCharacteristicUuid: string;
    FNotifyCharacteristicUuid: string;
    FWriteMode: TLazBleWriteMode;
    FSubscription: IBleSubscription;
    FDetachOperation: IBleGattOperation;
    FOnData: TLazBleByteChannelDataEvent;
    FSends: TInterfaceList;
    FStoppingSends: Boolean;
    procedure StartNextSend;
    procedure SendFinished(Sender: TObject);
    procedure StopSending(const AForce: Boolean);
    function GetSubscription: IBleSubscription;
    function GetState: TLazBleByteChannelState;
    function GetReady: Boolean;
    function GetOnData: TLazBleByteChannelDataEvent;
    procedure SetOnData(const AHandler: TLazBleByteChannelDataEvent);
    procedure SubscriptionDataReceived(Sender: TObject;
      const AValue: TBytes);
  public
    constructor Create(const ASession: TBleGattSession;
      const AServiceUuid, AWriteCharacteristicUuid,
      ANotifyCharacteristicUuid: string;
      const AWriteMode: TLazBleWriteMode);
    destructor Destroy; override;
    { Subscribe to notifications; inspect the returned subscription State. }
    function Attach: IBleSubscription;
    { Stop notifications and report the result through an operation. }
    function Detach: IBleGattOperation;
    { Send an owned byte snapshot in sequential connection-sized writes.
      Sends do not interleave. Failure/cancellation stops the remaining bytes;
      completed writes cannot be rolled back. Empty sends succeed locally. }
    function SendAsync(const AValue: TBytes): IBleGattOperation;
    property ServiceUuid: string read FServiceUuid;
    property WriteCharacteristicUuid: string read FWriteCharacteristicUuid;
    property NotifyCharacteristicUuid: string read FNotifyCharacteristicUuid;
    property WriteMode: TLazBleWriteMode read FWriteMode;
    property Subscription: IBleSubscription read GetSubscription;
    property State: TLazBleByteChannelState read GetState;
    property Ready: Boolean read GetReady;
    property OnData: TLazBleByteChannelDataEvent read GetOnData
      write SetOnData;
  end;

implementation

type
  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateTerminal(const AState: TLazBleOperationState;
      const AErrorMessage: string);
  end;

  TBleByteChannelSend = class(TBleGattOperation)
  private
    FChannel: TBleByteChannel;
    FData: TBytes;
    FOffset: SizeInt;
    FCurrent: IBleGattOperation;
    procedure CancelSend(Sender: TObject);
    procedure ChunkCompleted(Sender: TObject);
  public
    constructor Create(AChannel: TBleByteChannel; const AData: TBytes);
    procedure Start;
    procedure Abort;
  end;

constructor TBleByteChannelSend.Create(AChannel: TBleByteChannel;
  const AData: TBytes);
begin
  inherited CreateRequest(lbckWrite, @CancelSend, AChannel.FSession.Generation);
  FChannel := AChannel;
  FData := Copy(AData);
  OnFinishing := @AChannel.SendFinished;
end;

procedure TBleByteChannelSend.Start;
var Count: SizeInt; KeepAlive: IBleGattOperation;
begin
  KeepAlive := Self;
  if (State <> lbopPending) or Assigned(FCurrent) then Exit;
  if CancelRequested then
  begin
    Complete(lbopCancelled);
    Exit;
  end;
  if (FChannel.FSession.Generation <> OperationGeneration) or
    not FChannel.Ready then
  begin
    Complete(lbopFailed, LazBleErrorDeviceDisconnected,
      'BLE byte channel connection ended');
    Exit;
  end;
  if FOffset = Length(FData) then
  begin
    Complete(lbopSucceeded);
    Exit;
  end;
  Count := FChannel.FSession.MaxWriteSize;
  if Count = 0 then
  begin
    Complete(lbopFailed, LazBleErrorInvalidNativeData,
      'BLE write payload size is unavailable');
    Exit;
  end;
  if Count > Length(FData) - FOffset then Count := Length(FData) - FOffset;
  FCurrent := FChannel.FSession.WriteAsync(FChannel.FServiceUuid,
    FChannel.FWriteCharacteristicUuid, Copy(FData, FOffset, Count),
    FChannel.FWriteMode);
  Inc(FOffset, Count);
  FCurrent.OnCompleted := @ChunkCompleted;
end;

procedure TBleByteChannelSend.ChunkCompleted(Sender: TObject);
var Current, KeepAlive: IBleGattOperation;
begin
  KeepAlive := Self;
  Current := FCurrent;
  FCurrent := nil;
  Current.OnCompleted := nil;
  if Current.State <> lbopSucceeded then
    Complete(Current.State, Current.ErrorCode, Current.ErrorMessage)
  else if FOffset = Length(FData) then
    Complete(lbopSucceeded) { an in-flight final write retains its outcome }
  else
    Start;
end;

procedure TBleByteChannelSend.CancelSend(Sender: TObject);
var KeepAlive: IBleGattOperation;
begin
  KeepAlive := Self;
  if Assigned(FCurrent) then FCurrent.Cancel
  else Complete(lbopCancelled);
end;

procedure TBleByteChannelSend.Abort;
var Current, KeepAlive: IBleGattOperation;
begin
  KeepAlive := Self;
  Current := FCurrent;
  FCurrent := nil;
  if Assigned(Current) then
  begin
    Current.OnCompleted := nil;
    Current.Cancel;
  end;
  Complete(lbopCancelled);
end;

constructor TBleGattOperationAccess.CreateTerminal(
  const AState: TLazBleOperationState; const AErrorMessage: string);
begin
  inherited CreateCompleted(lbckWrite, AState, AErrorMessage);
end;

constructor TBleByteChannel.Create(const ASession: TBleGattSession;
  const AServiceUuid, AWriteCharacteristicUuid,
  ANotifyCharacteristicUuid: string; const AWriteMode: TLazBleWriteMode);
begin
  inherited Create;
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FSession := ASession;
  FServiceUuid := AServiceUuid;
  FWriteCharacteristicUuid := AWriteCharacteristicUuid;
  FNotifyCharacteristicUuid := ANotifyCharacteristicUuid;
  FWriteMode := AWriteMode;
  FSends := TInterfaceList.Create;
end;

destructor TBleByteChannel.Destroy;
begin
  Detach;
  StopSending(True);
  FSends.Free;
  SetOnData(nil);
  FSession := nil;
  FSubscription := nil;
  FDetachOperation := nil;
  inherited Destroy;
end;

function TBleByteChannel.GetSubscription: IBleSubscription;
begin
  LazBleRequireMainThread;
  Result := FSubscription;
end;

function TBleByteChannel.GetState: TLazBleByteChannelState;
var
  CurrentSubscription: IBleSubscription;
begin
  LazBleRequireMainThread;
  CurrentSubscription := GetSubscription;
  if not Assigned(CurrentSubscription) then
    Exit(lbchsDetached);
  case CurrentSubscription.State of
    lbsubPending:
      Result := lbchsSubscribing;
    lbsubActive:
      Result := lbchsReady;
    lbsubUnsubscribing:
      Result := lbchsUnsubscribing;
    lbsubFailed:
      Result := lbchsError;
    else
      Result := lbchsDetached;
  end;
end;

function TBleByteChannel.GetReady: Boolean;
begin
  LazBleRequireMainThread;
  Result := GetState = lbchsReady;
end;

function TBleByteChannel.GetOnData: TLazBleByteChannelDataEvent;
begin
  LazBleRequireMainThread;
  Result := FOnData;
end;

procedure TBleByteChannel.SetOnData(
  const AHandler: TLazBleByteChannelDataEvent);
begin
  LazBleRequireMainThread;
  FOnData := AHandler;
end;

procedure TBleByteChannel.SubscriptionDataReceived(Sender: TObject;
  const AValue: TBytes);
var
  Handler: TLazBleByteChannelDataEvent;
begin
  LazBleRequireMainThread;
  Handler := GetOnData;
  if Assigned(Handler) then
    Handler(Self, AValue);
end;

function TBleByteChannel.Attach: IBleSubscription;
var
  CurrentSubscription: IBleSubscription;
begin
  LazBleRequireMainThread;
  CurrentSubscription := GetSubscription;
  if Assigned(CurrentSubscription) and
    (CurrentSubscription.State in [lbsubPending, lbsubActive,
      lbsubUnsubscribing]) then
    Exit(CurrentSubscription);

  CurrentSubscription := FSession.SubscribeAsync(FServiceUuid,
    FNotifyCharacteristicUuid);
  CurrentSubscription.OnData := @SubscriptionDataReceived;
  FDetachOperation := nil;
  FSubscription := CurrentSubscription;
  Result := CurrentSubscription;
end;

function TBleByteChannel.Detach: IBleGattOperation;
var
  CurrentSubscription: IBleSubscription;
begin
  LazBleRequireMainThread;
  StopSending(False);
  Result := FDetachOperation;
  CurrentSubscription := FSubscription;
  if Assigned(Result) then
    Exit;
  if not Assigned(CurrentSubscription) then
    Exit(TBleGattOperationAccess.CreateTerminal(lbopSucceeded, ''));

  CurrentSubscription.OnData := nil;
  Result := CurrentSubscription.Unsubscribe;
  if not Assigned(FDetachOperation) then
    FDetachOperation := Result
  else
    Result := FDetachOperation;
end;

function TBleByteChannel.SendAsync(const AValue: TBytes): IBleGattOperation;
var Operation: TBleByteChannelSend;
begin
  LazBleRequireMainThread;
  if FStoppingSends or not Ready or not Assigned(FSession) then
    Exit(TBleGattOperationAccess.CreateTerminal(lbopFailed,
      'BLE byte channel is not ready'));
  Operation := TBleByteChannelSend.Create(Self, AValue);
  Result := Operation;
  FSends.Add(Result);
  StartNextSend;
end;

procedure TBleByteChannel.StartNextSend;
var Operation: IBleGattOperation;
begin
  if FStoppingSends or (FSends.Count = 0) then Exit;
  Operation := FSends[0] as IBleGattOperation;
  (Operation as TBleByteChannelSend).Start;
end;

procedure TBleByteChannel.SendFinished(Sender: TObject);
var Operation: TBleByteChannelSend;
begin
  Operation := TBleByteChannelSend(Sender);
  Operation.FChannel := nil;
  Operation.FData := nil;
  FSends.Remove(Operation as IBleGattOperation);
  StartNextSend;
end;

procedure TBleByteChannel.StopSending(const AForce: Boolean);
var Snapshot: array of IBleGattOperation; I: Integer;
begin
  if FStoppingSends or (FSends = nil) then Exit;
  SetLength(Snapshot, FSends.Count);
  for I := 0 to High(Snapshot) do Snapshot[I] := FSends[I] as IBleGattOperation;
  FStoppingSends := True;
  try
    for I := 0 to High(Snapshot) do
      if AForce then (Snapshot[I] as TBleByteChannelSend).Abort
      else Snapshot[I].Cancel;
  finally
    FStoppingSends := False;
  end;
end;

end.
