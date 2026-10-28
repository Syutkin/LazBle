unit LazBleReconnect;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes;

type
  TLazBleReconnectTimerEvent = procedure of object;

  { Main-thread API and callback. Start replaces the pending action; Cancel
    also removes an elapsed action queued for main-thread delivery. }
  ILazBleReconnectTimer = interface
    ['{CC96705B-0E67-4995-B8FB-BC617A0CC483}']
    procedure Start(const ADelayMs: Cardinal;
      const AHandler: TLazBleReconnectTimerEvent);
    procedure Cancel;
  end;

  ILazBleReconnectTimerFactory = interface
    ['{78375518-F070-40D1-89D2-BC256344985E}']
    function CreateTimer: ILazBleReconnectTimer;
  end;

  { Calculates retry delays and tracks attempts for one client. }
  TLazBleReconnectController = class
  private
    FTimer: ILazBleReconnectTimer;
    FOptions: TLazBleReconnectOptions;
    FEnabled: Boolean;
    FWaiting: Boolean;
    FAttempt: Cardinal;
    FDelayMs: Cardinal;
    FOnElapsed: TLazBleReconnectTimerEvent;
    procedure TimerElapsed;
    procedure ValidateOptions(const AOptions: TLazBleReconnectOptions);
    function GetEnabled: Boolean;
    function GetWaiting: Boolean;
    function GetAttempt: Cardinal;
    function GetDelayMs: Cardinal;
    function GetOptions: TLazBleReconnectOptions;
    function GetOnElapsed: TLazBleReconnectTimerEvent;
    procedure SetOnElapsed(const AHandler: TLazBleReconnectTimerEvent);
  public
    constructor Create(const ATimer: ILazBleReconnectTimer);
    destructor Destroy; override;
    procedure Enable;
    procedure Disable;
    procedure Reset;
    procedure Cancel;
    { Schedule the next retry; False means retries are disabled or exhausted. }
    function Schedule: Boolean;
    procedure SetOptions(const AOptions: TLazBleReconnectOptions);
    property Enabled: Boolean read GetEnabled;
    property Waiting: Boolean read GetWaiting;
    property Attempt: Cardinal read GetAttempt;
    property DelayMs: Cardinal read GetDelayMs;
    property Options: TLazBleReconnectOptions read GetOptions;
    property OnElapsed: TLazBleReconnectTimerEvent
      read GetOnElapsed write SetOnElapsed;
  end;

function LazBleCreateDefaultReconnectTimerFactory:
  ILazBleReconnectTimerFactory;

implementation

uses
  SyncObjs;

type
  TLazBleThreadReconnectTimer = class;
  TLazBleReconnectTimerThread = class(TThread)
  private
    FOwner: TLazBleThreadReconnectTimer;
    FDelayMs: Cardinal;
    FWakeEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(ADelayMs: Cardinal; AOwner: TLazBleThreadReconnectTimer);
    destructor Destroy; override;
    procedure Cancel;
  end;

  TLazBleThreadReconnectTimer = class(TInterfacedObject, ILazBleReconnectTimer)
  private
    FThread: TLazBleReconnectTimerThread;
    FHandler: TLazBleReconnectTimerEvent;
    procedure Fire;
  public
    destructor Destroy; override;
    procedure Start(const ADelayMs: Cardinal; const AHandler: TLazBleReconnectTimerEvent);
    procedure Cancel;
  end;

  TLazBleThreadReconnectTimerFactory = class(TInterfacedObject, ILazBleReconnectTimerFactory)
  public
    function CreateTimer: ILazBleReconnectTimer;
  end;

constructor TLazBleReconnectController.Create(
  const ATimer: ILazBleReconnectTimer);
begin
  inherited Create;
  if not Assigned(ATimer) then
    raise EArgumentNilException.Create('ATimer');
  FTimer := ATimer;
  FOptions := TLazBleReconnectOptions.Create(1000, 30000, 5);
end;

destructor TLazBleReconnectController.Destroy;
begin
  SetOnElapsed(nil);
  Disable;
  FTimer := nil;
  inherited Destroy;
end;

function TLazBleReconnectController.GetEnabled: Boolean;
begin
  LazBleRequireMainThread;
  Result := FEnabled;
end;

function TLazBleReconnectController.GetWaiting: Boolean;
begin
  LazBleRequireMainThread;
  Result := FWaiting;
end;

function TLazBleReconnectController.GetAttempt: Cardinal;
begin
  LazBleRequireMainThread;
  Result := FAttempt;
end;

function TLazBleReconnectController.GetDelayMs: Cardinal;
begin
  LazBleRequireMainThread;
  Result := FDelayMs;
end;

function TLazBleReconnectController.GetOptions: TLazBleReconnectOptions;
begin
  LazBleRequireMainThread;
  Result := FOptions;
end;

function TLazBleReconnectController.GetOnElapsed:
  TLazBleReconnectTimerEvent;
begin
  LazBleRequireMainThread;
  Result := FOnElapsed;
end;

procedure TLazBleReconnectController.SetOnElapsed(
  const AHandler: TLazBleReconnectTimerEvent);
begin
  LazBleRequireMainThread;
  FOnElapsed := AHandler;
end;

procedure TLazBleReconnectController.ValidateOptions(
  const AOptions: TLazBleReconnectOptions);
begin
  LazBleRequireMainThread;
  if AOptions.InitialDelayMs = 0 then
    raise EArgumentOutOfRangeException.Create('InitialDelayMs');
  if AOptions.MaximumDelayMs < AOptions.InitialDelayMs then
    raise EArgumentOutOfRangeException.Create('MaximumDelayMs');
  if AOptions.MaximumAttempts = 0 then
    raise EArgumentOutOfRangeException.Create('MaximumAttempts');
end;

procedure TLazBleReconnectController.SetOptions(
  const AOptions: TLazBleReconnectOptions);
begin
  LazBleRequireMainThread;
  ValidateOptions(AOptions);
  Cancel;
  FOptions := AOptions;
  FAttempt := 0;
end;

procedure TLazBleReconnectController.Enable;
begin
  LazBleRequireMainThread;
  FEnabled := True;
end;

procedure TLazBleReconnectController.Disable;
begin
  LazBleRequireMainThread;
  FEnabled := False;
  Reset;
end;

procedure TLazBleReconnectController.Reset;
begin
  LazBleRequireMainThread;
  Cancel;
  FAttempt := 0;
  FDelayMs := 0;
end;

procedure TLazBleReconnectController.Cancel;
begin
  LazBleRequireMainThread;
  FWaiting := False;
  FTimer.Cancel;
end;

function TLazBleReconnectController.Schedule: Boolean;
var
  ScheduledDelayMs: Cardinal;
  DoubledDelay: QWord;
begin
  LazBleRequireMainThread;
  Result := FEnabled and not FWaiting and
    (FAttempt < FOptions.MaximumAttempts);
  if not Result then
    Exit;
  Inc(FAttempt);
  if FAttempt = 1 then
    FDelayMs := FOptions.InitialDelayMs
  else
  begin
    DoubledDelay := QWord(FDelayMs) * 2;
    if DoubledDelay > FOptions.MaximumDelayMs then
      FDelayMs := FOptions.MaximumDelayMs
    else
      FDelayMs := Cardinal(DoubledDelay);
  end;
  FWaiting := True;
  ScheduledDelayMs := FDelayMs;
  FTimer.Start(ScheduledDelayMs, @TimerElapsed);
end;

procedure TLazBleReconnectController.TimerElapsed;
var
  Handler: TLazBleReconnectTimerEvent;
begin
  LazBleRequireMainThread;
  if not FEnabled or not FWaiting then
    Exit;
  FWaiting := False;
  Handler := FOnElapsed;
  if Assigned(Handler) then
    Handler;
end;

constructor TLazBleReconnectTimerThread.Create(ADelayMs: Cardinal;
  AOwner: TLazBleThreadReconnectTimer);
begin
  inherited Create(True);
  FDelayMs := ADelayMs;
  FOwner := AOwner;
  FWakeEvent := TEvent.Create(nil, True, False, '');
end;

destructor TLazBleReconnectTimerThread.Destroy;
begin
  FWakeEvent.Free;
  inherited Destroy;
end;

procedure TLazBleReconnectTimerThread.Cancel;
begin
  Terminate;
  FWakeEvent.SetEvent;
end;

procedure TLazBleReconnectTimerThread.Execute;
begin
  if (FWakeEvent.WaitFor(FDelayMs) = wrTimeout) and not Terminated then
    TThread.Queue(Self, @FOwner.Fire);
end;

destructor TLazBleThreadReconnectTimer.Destroy;
begin
  Cancel;
  inherited Destroy;
end;

procedure TLazBleThreadReconnectTimer.Start(const ADelayMs: Cardinal;
  const AHandler: TLazBleReconnectTimerEvent);
begin
  LazBleRequireMainThread;
  if ADelayMs = 0 then raise EArgumentOutOfRangeException.Create('ADelayMs');
  if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler');
  Cancel;
  FHandler := AHandler;
  FThread := TLazBleReconnectTimerThread.Create(ADelayMs, Self);
  FThread.Start;
end;

procedure TLazBleThreadReconnectTimer.Cancel;
var
  TimerThread: TLazBleReconnectTimerThread;
begin
  LazBleRequireMainThread;
  FHandler := nil;
  TimerThread := FThread;
  FThread := nil;
  if TimerThread = nil then Exit;
  TimerThread.Cancel;
  { The worker only waits/queues and never Synchronizes or calls a client.
    Join before removing its queue entry, including Queue racing with Cancel. }
  TimerThread.WaitFor;
  TThread.RemoveQueuedEvents(TimerThread);
  TimerThread.Free;
end;

procedure TLazBleThreadReconnectTimer.Fire;
var
  Handler: TLazBleReconnectTimerEvent;
begin
  LazBleRequireMainThread;
  Handler := FHandler;
  FHandler := nil;
  if Assigned(Handler) then Handler;
end;

function TLazBleThreadReconnectTimerFactory.CreateTimer:
  ILazBleReconnectTimer;
begin
  Result := TLazBleThreadReconnectTimer.Create;
end;

function LazBleCreateDefaultReconnectTimerFactory:
  ILazBleReconnectTimerFactory;
begin
  Result := TLazBleThreadReconnectTimerFactory.Create;
end;

end.
