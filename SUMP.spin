{{
┌─────────────────────────────────────────────────┐
│ Secondary Mode for Jtagulator: SUMP             │
│ Converts it into a SUMP-compatible Logic Analy- │
│ zer.                                            │
│                                                 │
│ Author: Ben Gardiner                            │                     
│ Copyright (c) 2015-2016 Ben Gardine             │
│                                                 │
│ Distributed under a Creative Commons            │
│ Attribution 3.0 United States license           │
│ http://creativecommons.org/licenses/by/3.0/us/  │
└─────────────────────────────────────────────────┘

TODOs:
* don't waste 1024B of the 4096B buffer
* capture pre-trigger samples
* support trigger delays
* support serial trigger mode
* support RLE

}}
   
   
CON                             
  MAX_INPUT_LEN                 = 5 ' SUMP long commands are five bytes
  MAX_SAMPLE_BYTES              = 4096
  MAX_PROBES                    = 24
  MAX_CH_GROUPS                 = MAX_PROBES / 8
  MAX_SAMPLE_PERIODS            = MAX_SAMPLE_BYTES / 4 'We capture 32bits at a time keep the sampler cog fast(er than it would be otherwise)
                                                       'TODO: don't waste 25% of the buffer *AND* get a >1Msps max sample rate :)

  ' used to convert between the protocol requests based on the OLS 100MHz clock and the JTAGulator's 80MHz clock
  SR_FACTOR_NUM                 = 4 ' 80E6/100E6 = 4/5
  SR_FACTOR_DEN                 = 5             
 
  CMD_RESET                     = $00
  CMD_RUN                       = $01
  CMD_QUERY_ID                  = $02               
  CMD_QUERY_META                = $04
  CMD_QUERY_INPUT_DATA          = $06
  CMD_DIV                       = $80
  CMD_CNT                       = $81
  CMD_FLAGS                     = $82
  CMD_TRIG1_MASK                = $C0
  CMD_TRIG2_MASK                = $C4
  CMD_TRIG3_MASK                = $C8
  CMD_TRIG4_MASK                = $CC
  CMD_TRIG1_VAL                 = $C1
  CMD_TRIG2_VAL                 = $C5
  CMD_TRIG3_VAL                 = $C9
  CMD_TRIG4_VAL                 = $CD
  CMD_TRIG1_CONF                = $C2
  CMD_TRIG2_CONF                = $C6
  CMD_TRIG3_CONF                = $CA
  CMD_TRIG4_CONF                = $CE  

  #0                            ' input processing states
  IDLE
  CHAIN

  DEFAULT_CLOCKS_WAIT           = 32 '2.5 MHz
  DEFAULT_READ_PERIODS          = MAX_SAMPLE_PERIODS 
  DEFAULT_DELAY_PERIODS         = DEFAULT_READ_PERIODS
  DEFAULT_DISABLE_FLAGS         = %00100000 ' disable ch group 4

  DISABLE_FLAGS_MASK            = %00111100

  TRIGGER_CH_MASK               = %00000000111111111111111111111111
    
VAR
  byte vCmd[MAX_INPUT_LEN + 1]  ' Buffer for command input string
  long larg

CON 'offsets of the structure below
  CLOCKSWAIT_OFF              =  0
  READPERIODS_OFF             =  4
  DELAYPERIODS_OFF            =  8
  DISABLEFLAGS_OFF            = 12
  TRIG1MASK_OFF               = 16
  TRIG2MASK_OFF               = 20
  TRIG3MASK_OFF               = 24
  TRIG4MASK_OFF               = 28
  TRIG1VAL_OFF                = 32
  TRIG2VAL_OFF                = 36
  TRIG3VAL_OFF                = 40
  TRIG4VAL_OFF                = 44
  ISTRIG1START_OFF            = 48
  ISTRIG2START_OFF            = 52
  ISTRIG3START_OFF            = 56
  ISTRIG4START_OFF            = 60
  SAMPLERRUNNING_OFF          = 64
  SAMPLEBUFFER_OFF            = 68

VAR 'This is a struct used by the sampler; its layout and the offsets above must be in sync
  long clocksWait 'struct head
  long readPeriods
  long delayPeriods
  long disableFlags

  long trig1Mask
  long trig2Mask
  long trig3Mask
  long trig4Mask

  long trig1Val
  long trig2Val
  long trig3Val
  long trig4Val

  long isTrig1Start
  long isTrig2Start
  long isTrig3Start
  long isTrig4Start

  long samplerRunning

  long sampleBuffer[MAX_SAMPLE_BYTES]
  
OBJ
  ser           : "PropSerial"  
  led           : "LED"
 
PUB Go | firstByte, state, count, coggood, i                                                                                                                         
  ser.Start(115_200)            ' Start serial communications
  ' Start command receive/process cycle
  dira[23..0]~                  ' Set P23-P0 as inputs
  state:=IDLE
               
  clocksWait:=DEFAULT_CLOCKS_WAIT
  readPeriods:=DEFAULT_READ_PERIODS 
  delayPeriods:=DEFAULT_DELAY_PERIODS
  disableFlags:=DEFAULT_DISABLE_FLAGS

  trig1Mask:=0
  trig2Mask:=0
  trig3Mask:=0
  trig4Mask:=0

  trig1Val:=0
  trig2Val:=0
  trig3Val:=0
  trig4Val:=0

  isTrig1Start:=1
  isTrig2Start:=1
  isTrig3Start:=1
  isTrig4Start:=1

  samplerRunning:=0

  led.Init
  led.Green            

  coggood:=cognew(@samplerInit, @clocksWait)
  if coggood =< 0
    ser.Str(String("Failed to start SUMP Sampler"))
    return

  repeat
    firstByte := ser.CharInNoEcho
     
    case state
      IDLE:
        case firstByte
          CMD_RESET:
          'do nothing
           samplerRunning:=0
             repeat while i < MAX_SAMPLE_PERIODS
                sampleBuffer[i++] := %01101001

          CMD_QUERY_ID, $31:
            ser.StrMax(@ID, @METADATA - @ID)
         
          CMD_QUERY_META:
            ser.StrMax(@METADATA, @END_METADATA - @METADATA + 1)
         
          CMD_QUERY_INPUT_DATA: 
            SendSamples(ina[23..0])

          CMD_RUN:
            led.Yellow
            samplerRunning:=1
            repeat until (samplerRunning == 0)
            led.Red
            SendAllSamples
            led.Green
          
          other:
            count:=0
            vCmd[0]:=firstByte
            state:=CHAIN

      CHAIN:
        count++
        vCmd[count]:=firstByte                               
        if count == MAX_INPUT_LEN - 1
          state:=IDLE

          case vCmd[0]
            CMD_CNT:
              larg:=vCmd[2]
              larg<<=8
              larg|=vCmd[1]
              readPeriods:=(larg+1)*4 'the protocol doesn't indicate the +1 is needed; but sigrok's ols api does
              if readPeriods > MAX_SAMPLE_PERIODS
                readPeriods:=MAX_SAMPLE_PERIODS 

              larg:=vCmd[4]
              larg<<=8
              larg|=vCmd[3]
              delayPeriods:=(larg+1)*4 'the protocol doesn't indicate the +1 is needed; but sigrok's ols api does

              'TODO: support readPeriods > delayPeriods (i.e. capturing pre-trigger window)
              if readPeriods > delayPeriods
                readPeriods := delayPeriods
                                
            CMD_DIV:
              larg:=vCmd[3]
              larg<<=8
              larg|=vCmd[2]
              larg<<=8
              larg|=vCmd[1]

              clocksWait:=((larg+1)*SR_FACTOR_NUM)/SR_FACTOR_DEN
            
            CMD_FLAGS:
              disableFlags:=vCmd[1] & DISABLE_FLAGS_MASK

            CMD_TRIG1_MASK:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]

              trig1Mask:=larg & TRIGGER_CH_MASK            

            CMD_TRIG2_MASK:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig2Mask:=larg & TRIGGER_CH_MASK

            CMD_TRIG3_MASK:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig3Mask:=larg & TRIGGER_CH_MASK

            CMD_TRIG4_MASK:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig4Mask:=larg & TRIGGER_CH_MASK

            CMD_TRIG1_VAL:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig1Val:=larg & TRIGGER_CH_MASK            

            CMD_TRIG2_VAL:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig2Val:=larg & TRIGGER_CH_MASK

            CMD_TRIG3_VAL:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig3Val:=larg & TRIGGER_CH_MASK

            CMD_TRIG4_VAL:
              larg:=vCmd[4]
              larg<<=8
              larg:=vCmd[3]
              larg<<=8
              larg:=vCmd[2]
              larg<<=8
              larg:=vCmd[1]
              
              trig4Val:=larg & TRIGGER_CH_MASK

            'TODO: support full triggers including delays and serial forms; for now support only sigrok OLS features
            CMD_TRIG1_CONF:
              isTrig1Start:=(vCmd[4] & 1<<3)
              
            CMD_TRIG2_CONF:
              isTrig2Start:=(vCmd[4] & 1<<3)

            CMD_TRIG3_CONF:
              isTrig3Start:=(vCmd[4] & 1<<3)

            CMD_TRIG4_CONF:
              isTrig4Start:=(vCmd[4] & 1<<3) ' NB: ignored; all 4th stage triggers start the sampler
                            
PRI SendAllSamples | i 'NB: OLS sends samples in reverse
  i := 0
  repeat while i < readPeriods
    SendSamples(sampleBuffer[delayPeriods - 1 - i++])

PRI SendSamples(value) | b
  'bits:            %76543210
  'ch disable flag:  --4321--
  if disableFlags & %00000100 == 0
    b:=(value) & $FF
    ser.Char(b) 
  'ch disable flag:  --4321--
  if disableFlags & %00001000 == 0
    b:=(value >> 8) & $FF
    ser.Char(b)    
  'ch disable flag:  --4321--
  if disableFlags & %00010000 == 0
    b:=(value >> 16) & $FF
    ser.Char(b)
  'ch disable flag:  --4321--
  if disableFlags & %00100000 == 0
    b:=0
    ser.Char(b)
 
DAT             

              ORG
ID            byte "1ALS"

METADATA      byte $01, "JTAGulator", $00 ' device name
              byte $02, "1.0.0", $00      ' firmware version
              byte $03, "0.0", $00        ' ancilliary version
              byte $21
              byte $00, $00, $0c, $00     ' sample memory 3072 in MSB -- must match MAX_SAMPLE_PERIODS*MAX_CH_GROUPS
              byte $23
              byte $00, $12, $4F, $80     ' 1_200_000 in MSB -- highest stable sample rate
              byte $40
              byte MAX_PROBES             ' number of probes
              byte $41
              byte $02                    ' protocol version 2
END_METADATA  byte $00

'*****************************
'* the sampler               *
'*****************************

                        ORG
samplerInit             MOVS    samplerTramp,       #samplerOff
                        MOV     samplerRunningA,    PAR
                        ADD     samplerRunningA,    #SAMPLERRUNNING_OFF

                        MOV     samplerTargetA,     PAR
                        ADD     samplerTargetA,     #SAMPLEBUFFER_OFF

                        JMP     #samplerCommon

'check samplerRunning; arm if set
samplerOff              RDLONG  t1,                 samplerRunningA     WZ
              IF_NE     MOVS    samplerTramp,       #samplerArm
                        JMP     #samplerCommon 
                        
samplerArm              MOVS    samplerTramp,       #samplerArmed1

                        MOV     t1,                 PAR
                        ADD     t1,                 #DELAYPERIODS_OFF
                        RDLONG  samplerLimitA,      t1
                        SHL     samplerLimitA,      #2                     ' we capture 4ch at a time
                        ADD     samplerLimitA,      samplerTargetA

                        MOV     t1,                 PAR
                        ADD     t1,                 #CLOCKSWAIT_OFF
                        RDLONG  samplerWait,        t1

                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG1VAL_OFF
                        RDLONG  samplerTrigVal,     t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG1MASK_OFF
                        RDLONG  samplerTrigMask,    t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #ISTRIG1START_OFF
                        RDLONG  samplerTrigStart,   t1
                        
                        JMP     #samplerCommon

samplerArmed1           CMP     samplerTrigMask,    #0                  WZ
              IF_NE     WAITPEQ samplerTrigVal,     samplerTrigMask

                        CMP     samplerTrigStart,   #0                  WZ
              IF_NE     MOVS    samplerTramp,       #samplerStart
              IF_NE     JMP     #samplerCommon

                        MOVS    samplerTramp,       #samplerArmed2
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG2VAL_OFF
                        RDLONG  samplerTrigVal,     t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG2MASK_OFF
                        RDLONG  samplerTrigMask,    t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #ISTRIG2START_OFF
                        RDLONG  samplerTrigStart,   t1
                        JMP     #samplerCommon

samplerArmed2           CMP     samplerTrigMask,    #0                  WZ
              IF_NE     WAITPEQ samplerTrigVal,     samplerTrigMask

                        CMP     samplerTrigStart,   #0                  WZ
              IF_NE     MOVS    samplerTramp,       #samplerStart
              IF_NE     JMP     #samplerCommon

                        MOVS    samplerTramp,       #samplerArmed3
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG3VAL_OFF
                        RDLONG  samplerTrigVal,     t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG3MASK_OFF
                        RDLONG  samplerTrigMask,    t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #ISTRIG3START_OFF
                        RDLONG  samplerTrigStart,   t1
                        JMP     #samplerCommon

samplerArmed3           CMP     samplerTrigMask,    #0                  WZ
              IF_NE     WAITPEQ samplerTrigVal,     samplerTrigMask

                        CMP     samplerTrigStart,   #0                  WZ
              IF_NE     MOVS    samplerTramp,       #samplerStart
              IF_NE     JMP     #samplerCommon

                        MOVS    samplerTramp,       #samplerArmed4
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG4VAL_OFF
                        RDLONG  samplerTrigVal,     t1
                        MOV     t1,                 PAR
                        ADD     t1,                 #TRIG4MASK_OFF
                        RDLONG  samplerTrigMask,    t1
                        JMP     #samplerCommon

samplerArmed4           CMP     samplerTrigMask,    #0                  WZ
              IF_NE     WAITPEQ samplerTrigVal,     samplerTrigMask

                        MOVS    samplerTramp,       #samplerStart
                        JMP     #samplerCommon
                                  
samplerStart            MOVS    samplerTramp,       #samplerSampling
                        MOV     samplerStamp,       CNT
                        ADD     samplerStamp,       samplerWait
                        JMP     #samplerCommon

'Capable of achieving 1.2MHz. Rate limiting step is WRLONG
samplerSampling         MOV     t1,                 INA
                        WRLONG  t1,                 samplerTargetA
                        ADD     samplerTargetA,     #4                      'TODO: inc by 3 here (and waste a byte before the buffer) to reclaim waster 1/4 of 4096 buffer
                        
                        CMP     samplerTargetA,     samplerLimitA       WZ
              IF_E      MOVS    samplerTramp,       #samplerFinish

              IF_NE     WAITCNT samplerStamp,       samplerWait
samplerCommon           JMP     samplerTramp

samplerFinish           MOVS    samplerTramp,       #samplerOff

                        MOV     t1,                 #0
                        WRLONG  t1,                 samplerRunningA        'NB always sets Z
                        JMP     #samplerCommon

t1                      RES 1
samplerTramp            RES 1
samplerRunningA         RES 1
samplerTrigVal          RES 1
samplerTrigMask         RES 1
samplerTrigStart        RES 1
samplerTargetA          RES 1
samplerLimitA           RES 1
samplerStamp            RES 1
samplerWait             RES 1

'****************************
