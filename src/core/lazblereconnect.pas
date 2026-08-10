unit LazBleReconnect;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes,
  SysUtils;

type
  TLazBleReconnectOptions = record
    InitialDelayMs: Cardinal;
    MaximumDelayMs: Cardinal;
    MaximumAttempts: Cardinal;
    class function Create(const AInitialDelayMs, AMaximumDelayMs,
      AMaximumAttempts: Cardinal): TLazBleReconnectOptions; static;
  end;

  TLazBleReconnectTimerEvent = procedure of object;

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
  public
    constructor Create(const ATimer: ILazBleReconnectTimer);
    destructor Destroy; override;
    procedure Enable;
    procedure Disable;
    procedure Reset;
    procedure Cancel;
    function Schedule: Boolean;
    procedure SetOptions(const AOptions: TLazBleReconnectOptions);
    property Enabled: Boolean read FEnabled;
    property Waiting: Boolean read FWaiting;
    property Attempt: Cardinal read FAttempt;
    property DelayMs: Cardinal read FDelayMs;
    property Options: TLazBleReconnectOptions read FOptions;
    property OnElapsed: TLazBleReconnectTimerEvent
      read FOnElapsed write FOnElapsed;
  end;

function LazBleCreateDefaultReconnectTimerFactory:
  ILazBleReconnectTimerFactory;

implementation

uses
  SyncObjs;

type
  ILazBleReconnectTimerInternal = interface
    ['{A423B289-DA75-49A8-8316-884714AA8C0C}']
    procedure Fire;
  end;

  TLazBleThreadReconnectTimer = class;

  TLazBleReconnectTimerThread = class(TThread)
  private
    FDelayMs: Cardinal;
    FOwner: ILazBleReconnectTimerInternal;
    FWakeEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADelayMs: Cardinal;
      const AOwner: ILazBleReconnectTimerInternal);
    destructor Destroy; override;
    procedure Cancel;
  end;

  TLazBleThreadReconnectTimer = class(TInterfacedObject,
    ILazBleReconnectTimer, ILazBleReconnectTimerInternal)
  private
    FLock: TRTLCriticalSection;
    FThread: TLazBleReconnectTimerThread;
    FHandler: TLazBleReconnectTimerEvent;
    procedure Fire;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const ADelayMs: Cardinal;
      const AHandler: TLazBleReconnectTimerEvent);
    procedure Cancel;
  end;

  TLazBleThreadReconnectTimerFactory = class(TInterfacedObject,
    ILazBleReconnectTimerFactory)
  public
    function CreateTimer: ILazBleReconnectTimer;
  end;

class function TLazBleReconnectOptions.Create(const AInitialDelayMs,
  AMaximumDelayMs, AMaximumAttempts: Cardinal): TLazBleReconnectOptions;
begin
  Result.InitialDelayMs := AInitialDelayMs;
  Result.MaximumDelayMs := AMaximumDelayMs;
  Result.MaximumAttempts := AMaximumAttempts;
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
  FOnElapsed := nil;
  Disable;
  FTimer := nil;
  inherited Destroy;
end;

procedure TLazBleReconnectController.ValidateOptions(
  const AOptions: TLazBleReconnectOptions);
begin
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
  ValidateOptions(AOptions);
  Cancel;
  FOptions := AOptions;
  FAttempt := 0;
end;

procedure TLazBleReconnectController.Enable;
begin
  FEnabled := True;
end;

procedure TLazBleReconnectController.Disable;
begin
  FEnabled := False;
  Reset;
end;

procedure TLazBleReconnectController.Reset;
begin
  Cancel;
  FAttempt := 0;
  FDelayMs := 0;
end;

procedure TLazBleReconnectController.Cancel;
begin
  FWaiting := False;
  FTimer.Cancel;
end;

function TLazBleReconnectController.Schedule: Boolean;
var
  DoubledDelay: QWord;
begin
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
  FTimer.Start(FDelayMs, @TimerElapsed);
end;

procedure TLazBleReconnectController.TimerElapsed;
var
  Handler: TLazBleReconnectTimerEvent;
begin
  if not FEnabled or not FWaiting then
    Exit;
  FWaiting := False;
  Handler := FOnElapsed;
  if Assigned(Handler) then
    Handler;
end;

constructor TLazBleReconnectTimerThread.Create(const ADelayMs: Cardinal;
  const AOwner: ILazBleReconnectTimerInternal);
begin
  inherited Create(True);
  FreeOnTerminate := False;
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
var
  Owner: ILazBleReconnectTimerInternal;
begin
  if (FWakeEvent.WaitFor(FDelayMs) = wrTimeout) and not Terminated then
  begin
    Owner := FOwner;
    if Assigned(Owner) then
      Owner.Fire;
    Owner := nil;
  end;
  FOwner := nil;
end;

constructor TLazBleThreadReconnectTimer.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor TLazBleThreadReconnectTimer.Destroy;
begin
  Cancel;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLazBleThreadReconnectTimer.Start(const ADelayMs: Cardinal;
  const AHandler: TLazBleReconnectTimerEvent);
var
  Owner: ILazBleReconnectTimerInternal;
begin
  if ADelayMs = 0 then
    raise EArgumentOutOfRangeException.Create('ADelayMs');
  if not Assigned(AHandler) then
    raise EArgumentNilException.Create('AHandler');
  Cancel;
  EnterCriticalSection(FLock);
  try
    FHandler := AHandler;
    Owner := Self;
    FThread := TLazBleReconnectTimerThread.Create(ADelayMs, Owner);
    FThread.Start;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLazBleThreadReconnectTimer.Cancel;
var
  TimerThread: TLazBleReconnectTimerThread;
begin
  EnterCriticalSection(FLock);
  try
    FHandler := nil;
    TimerThread := FThread;
    FThread := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not Assigned(TimerThread) then
    Exit;
  TimerThread.Cancel;
  if TimerThread.ThreadID = GetCurrentThreadId then
    TimerThread.FreeOnTerminate := True
  else
  begin
    TimerThread.WaitFor;
    TimerThread.Free;
  end;
end;

procedure TLazBleThreadReconnectTimer.Fire;
var
  Handler: TLazBleReconnectTimerEvent;
begin
  EnterCriticalSection(FLock);
  try
    Handler := FHandler;
    FHandler := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Assigned(Handler) then
    Handler;
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
