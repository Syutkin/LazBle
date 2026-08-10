unit LazBleComponentClientTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  FpcUnit,
  TestRegistry,
  LazBleBackend,
  LazBleComponent,
  FakeLazBleBackend;

type
  TTrackedLazBleLclClient = class(TLazBleLclClient)
  private
    FDestroyCount: PInteger;
  public
    constructor Create(AOwner: TComponent;
      const ADestroyCount: PInteger); reintroduce;
    destructor Destroy; override;
  end;

  TLazBleComponentClientTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FLazBle: TLazBleComponent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CreateClientRegistersRootOwnedClientWithoutBleOperation;
    procedure PreplacedClientRegistersAndUnregistersThroughLazBleProperty;
    procedure DuplicateDeviceIdIsRejectedWithoutChangingExistingBinding;
    procedure RemoveClientFreesOnlyRootOwnedClient;
    procedure RemoveClientRejectsActiveConnection;
    procedure RootDestructionDetachesPreplacedActiveClientFirst;
  end;

implementation

constructor TTrackedLazBleLclClient.Create(AOwner: TComponent;
  const ADestroyCount: PInteger);
begin
  inherited Create(AOwner);
  FDestroyCount := ADestroyCount;
end;

destructor TTrackedLazBleLclClient.Destroy;
begin
  if Assigned(FDestroyCount) then
    Inc(FDestroyCount^);
  inherited Destroy;
end;

procedure TLazBleComponentClientTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FLazBle := TLazBleComponent.Create(nil, FBackend);
end;

procedure TLazBleComponentClientTest.TearDown;
begin
  FLazBle.Free;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleComponentClientTest.CreateClientRegistersRootOwnedClientWithoutBleOperation;
var
  Client: TLazBleLclClient;
begin
  Client := FLazBle.CreateClient('device-a');

  AssertSame(FLazBle, Client.Owner);
  AssertSame(FLazBle, Client.LazBle);
  AssertEquals('device-a', Client.DeviceId);
  AssertEquals(1, FLazBle.ClientCount);
  AssertSame(Client, FLazBle.Clients[0]);
  AssertSame(Client, FLazBle.FindClient('DEVICE-A'));
  AssertNull(Client.CoreClient);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleComponentClientTest.PreplacedClientRegistersAndUnregistersThroughLazBleProperty;
var
  Client: TLazBleLclClient;
begin
  Client := TLazBleLclClient.Create(nil);
  try
    Client.DeviceId := 'preplaced';
    Client.LazBle := FLazBle;

    AssertEquals(1, FLazBle.ClientCount);
    AssertSame(Client, FLazBle.FindClient('preplaced'));

    Client.LazBle := nil;

    AssertEquals(0, FLazBle.ClientCount);
    AssertNull(FLazBle.FindClient('preplaced'));
    AssertEquals('preplaced', Client.DeviceId);
    AssertEquals(0, FBackendObject.CommandCount);
  finally
    Client.Free;
  end;
end;

procedure TLazBleComponentClientTest.DuplicateDeviceIdIsRejectedWithoutChangingExistingBinding;
var
  FirstClient: TLazBleLclClient;
  Raised: Boolean;
  SecondClient: TLazBleLclClient;
begin
  FirstClient := TLazBleLclClient.Create(nil);
  SecondClient := TLazBleLclClient.Create(nil);
  try
    FirstClient.DeviceId := 'device-a';
    FirstClient.LazBle := FLazBle;
    SecondClient.DeviceId := 'DEVICE-A';

    Raised := False;
    try
      SecondClient.LazBle := FLazBle;
    except
      on ELazBleLclDuplicateClient do
        Raised := True;
    end;
    AssertTrue(Raised);
    AssertNull(SecondClient.LazBle);
    AssertEquals(1, FLazBle.ClientCount);

    SecondClient.DeviceId := 'device-b';
    SecondClient.LazBle := FLazBle;
    Raised := False;
    try
      SecondClient.DeviceId := 'device-a';
    except
      on ELazBleLclDuplicateClient do
        Raised := True;
    end;
    AssertTrue(Raised);
    AssertEquals('device-b', SecondClient.DeviceId);
    AssertEquals(2, FLazBle.ClientCount);
  finally
    SecondClient.Free;
    FirstClient.Free;
  end;
end;

procedure TLazBleComponentClientTest.RemoveClientFreesOnlyRootOwnedClient;
var
  Client: TLazBleLclClient;
  DestroyCount: Integer;
  PreplacedClient: TTrackedLazBleLclClient;
begin
  Client := FLazBle.CreateClient('owned');
  FLazBle.RemoveClient(Client);
  AssertEquals(0, FLazBle.ClientCount);
  AssertNull(FLazBle.FindClient('owned'));

  DestroyCount := 0;
  PreplacedClient := TTrackedLazBleLclClient.Create(nil, @DestroyCount);
  try
    PreplacedClient.DeviceId := 'preplaced';
    PreplacedClient.LazBle := FLazBle;

    FLazBle.RemoveClient(PreplacedClient);

    AssertEquals(0, DestroyCount);
    AssertNull(PreplacedClient.LazBle);
    AssertEquals(0, FLazBle.ClientCount);
  finally
    PreplacedClient.Free;
  end;
  AssertEquals(1, DestroyCount);
end;

procedure TLazBleComponentClientTest.RemoveClientRejectsActiveConnection;
var
  Client: TLazBleLclClient;
  Raised: Boolean;
begin
  Client := FLazBle.CreateClient('active');
  Client.Connect;

  Raised := False;
  try
    FLazBle.RemoveClient(Client);
  except
    on EInvalidOperation do
      Raised := True;
  end;

  AssertTrue(Raised);
  AssertEquals(1, FLazBle.ClientCount);
  AssertSame(Client, FLazBle.FindClient('active'));
  AssertSame(FLazBle, Client.LazBle);
end;

procedure TLazBleComponentClientTest.RootDestructionDetachesPreplacedActiveClientFirst;
var
  Client: TLazBleLclClient;
begin
  Client := TLazBleLclClient.Create(nil);
  try
    Client.DeviceId := 'active';
    Client.LazBle := FLazBle;
    Client.Connect;

    FLazBle.Free;
    FLazBle := nil;

    AssertNull(Client.LazBle);
    AssertNull(Client.CoreClient);
    AssertFalse(FBackendObject.HasEventSink);
    CheckSynchronize;
  finally
    Client.Free;
  end;
end;

initialization
  RegisterTest(TLazBleComponentClientTest);

end.
