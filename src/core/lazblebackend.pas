unit LazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

type
  ILazBleBackendEventSink = interface
    ['{1F4A66C4-5739-4428-902D-B09F59039602}']
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  ILazBleBackend = interface
    ['{62F13659-C033-47B2-8926-B495B05D83D7}']
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
  end;

implementation

end.
