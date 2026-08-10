unit LazBleByteChannel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
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

  TBleByteChannel = class
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FSession: TBleGattSession;
    FServiceUuid: string;
    FWriteCharacteristicUuid: string;
    FNotifyCharacteristicUuid: string;
    FWriteMode: TLazBleWriteMode;
    FSubscription: IBleSubscription;
    FDetachOperation: IBleGattOperation;
    FOnData: TLazBleByteChannelDataEvent;
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
    function Attach: IBleSubscription;
    function Detach: IBleGattOperation;
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
  InitCriticalSection(FLock);
  InitCriticalSection(FCallbackLock);
  FSession := ASession;
  FServiceUuid := AServiceUuid;
  FWriteCharacteristicUuid := AWriteCharacteristicUuid;
  FNotifyCharacteristicUuid := ANotifyCharacteristicUuid;
  FWriteMode := AWriteMode;
end;

destructor TBleByteChannel.Destroy;
begin
  Detach;
  SetOnData(nil);
  EnterCriticalSection(FLock);
  try
    FSession := nil;
    FSubscription := nil;
    FDetachOperation := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TBleByteChannel.GetSubscription: IBleSubscription;
begin
  EnterCriticalSection(FLock);
  try
    Result := FSubscription;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleByteChannel.GetState: TLazBleByteChannelState;
var
  CurrentSubscription: IBleSubscription;
begin
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
  Result := GetState = lbchsReady;
end;

function TBleByteChannel.GetOnData: TLazBleByteChannelDataEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnData;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleByteChannel.SetOnData(
  const AHandler: TLazBleByteChannelDataEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnData := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleByteChannel.SubscriptionDataReceived(Sender: TObject;
  const AValue: TBytes);
var
  Handler: TLazBleByteChannelDataEvent;
begin
  Handler := GetOnData;
  if Assigned(Handler) then
    Handler(Self, AValue);
end;

function TBleByteChannel.Attach: IBleSubscription;
var
  CurrentSubscription: IBleSubscription;
begin
  CurrentSubscription := GetSubscription;
  if Assigned(CurrentSubscription) and
    (CurrentSubscription.State in [lbsubPending, lbsubActive,
      lbsubUnsubscribing]) then
    Exit(CurrentSubscription);

  CurrentSubscription := FSession.SubscribeAsync(FServiceUuid,
    FNotifyCharacteristicUuid);
  CurrentSubscription.OnData := @SubscriptionDataReceived;
  EnterCriticalSection(FLock);
  try
    FDetachOperation := nil;
    FSubscription := CurrentSubscription;
  finally
    LeaveCriticalSection(FLock);
  end;
  Result := CurrentSubscription;
end;

function TBleByteChannel.Detach: IBleGattOperation;
var
  CurrentSubscription: IBleSubscription;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDetachOperation;
    CurrentSubscription := FSubscription;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(Result) then
    Exit;
  if not Assigned(CurrentSubscription) then
    Exit(TBleGattOperationAccess.CreateTerminal(lbopSucceeded, ''));

  CurrentSubscription.OnData := nil;
  Result := CurrentSubscription.Unsubscribe;
  EnterCriticalSection(FLock);
  try
    if not Assigned(FDetachOperation) then
      FDetachOperation := Result
    else
      Result := FDetachOperation;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleByteChannel.SendAsync(const AValue: TBytes): IBleGattOperation;
begin
  if not Ready or not Assigned(FSession) then
    Exit(TBleGattOperationAccess.CreateTerminal(lbopFailed,
      'BLE byte channel is not ready'));
  Result := FSession.WriteAsync(FServiceUuid, FWriteCharacteristicUuid,
    AValue, FWriteMode);
end;

end.
