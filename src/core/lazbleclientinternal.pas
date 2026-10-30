unit LazBleClientInternal;

{$mode objfpc}{$H+}

interface

uses
  LazBleOperation,
  LazBleGattSession;

type
  TLazBleConnectSessionEvent = function(const ADeviceId: string):
    IBleOperation of object;
  TLazBleDisconnectSessionEvent = function(
    const ASession: TBleGattSession): IBleOperation of object;

implementation

end.
