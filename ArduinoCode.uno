#include <SPI.h>
#include <MFRC522.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <LiquidCrystal_I2C.h>
#include <Wire.h>
#include <ESP32Servo.h>
#include "DHT.h" 

//---------------- PIN SETUP ----------------
// Entrance Reader
#define SS_PIN_1   5
#define RST_PIN_1  4

// Exit Reader
#define SS_PIN_2   15
#define RST_PIN_2  16

#define BUZZER     2

// Servos
#define SERVO_IN_PIN   12
#define SERVO_OUT_PIN  27

// IR Sensors (Active LOW)
#define IR_IN_PIN      14
#define IR_OUT_PIN     26

// Shared MQ-2 Gas Sensors
#define MQ2_PARALLEL_ANALOG_PIN   34
#define MQ2_PARALLEL_DIGITAL_PIN  35
#define SMOKE_THRESHOLD           1500  

// DHT Sensors (Temperature)
#define DHTPIN1 32
#define DHTPIN2 33
#define DHTTYPE DHT11 // Change to DHT22 if using DHT22
DHT dht1(DHTPIN1, DHTTYPE);
DHT dht2(DHTPIN2, DHTTYPE);

// LDR Sensors (Light Level)
#define LDR_PIN_1 36
#define LDR_PIN_2 39

// 2-Channel Relay Control
#define RELAY_FANS_PIN 25
#define RELAY_LEDS_PIN 17

// System Thresholds
#define TEMP_THRESHOLD_HIGH 33.0  // Â°C threshold to activate fans
#define LIGHT_THRESHOLD_LOW 400// ADC threshold (0-4095) for darkness (lower = darker)

// Servo Positions
#define DOOR_OPEN  90
#define DOOR_CLOSE 0

MFRC522 mfrc522_in(SS_PIN_1, RST_PIN_1);
MFRC522 mfrc522_out(SS_PIN_2, RST_PIN_2);

Servo servoIn;
Servo servoOut;

//---------------- WIFI ----------------
#define WIFI_SSID "smartclassroom"
#define WIFI_PASSWORD "12345678"

String sheet_url = "https://script.google.com/macros/s/AKfycbxO18ji3S-hfSHJeR84yVVsrUuwHVVdW1cb7uvLKXnUpeWk-9DKi1cqQIBIbIbVgFg3NQ/exec";

WiFiClientSecure client;

//---------------- LCD ----------------
LiquidCrystal_I2C lcd(0x27, 16, 2);

//---------------- USER STATE TRACKING ----------------
struct User {
  String uid;
  String roll;
  String name;
  bool isInside;
};

User users[] = {
  {"52 7C 21 07", "1", "AyeAye", false},
  {"63 4B E6 06", "2", "MgMg", false},
  {"BB 1C E7 06", "3", "KyawKyaw", false},
  {"43 79 C6 9F", "4", "NyiNyi", false},
  {"04 7C 91 5E", "5", "KoKo", false}  
};

const int NUM_USERS = sizeof(users) / sizeof(users[0]);
bool isEmergency = false;

// Serial Print Timer
unsigned long lastSerialPrint = 0;

// Function Prototypes
void displayIdleStatus();
void checkFireAlarm();
void checkReader(MFRC522 &mfrc, String scanType);
bool handleDoorOpening(String scanType, String userName);
void triggerErrorBuzzer();
void sendToGoogleSheets(String roll, String name, String scanType);
int getPresentCount();
void updateEnvironmentalControls();

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);

  lcd.init();
  lcd.backlight();
  lcd.print("Initializing...");

  pinMode(BUZZER, OUTPUT);
  pinMode(SS_PIN_1, OUTPUT);
  pinMode(SS_PIN_2, OUTPUT);

  // Relay Setup (Active LOW relays default OFF = HIGH)
  pinMode(RELAY_FANS_PIN, OUTPUT);
  pinMode(RELAY_LEDS_PIN, OUTPUT);
  digitalWrite(RELAY_FANS_PIN, HIGH);
  digitalWrite(RELAY_LEDS_PIN, HIGH);

  // Initialize DHT Sensors
  dht1.begin();
  dht2.begin();

  // IR Sensors
  pinMode(IR_IN_PIN, INPUT_PULLUP);
  pinMode(IR_OUT_PIN, INPUT_PULLUP);

  // MQ-2 Gas Sensor Input Setup
  pinMode(MQ2_PARALLEL_DIGITAL_PIN, INPUT_PULLUP);

  // Servos Setup
  servoIn.attach(SERVO_IN_PIN);
  servoOut.attach(SERVO_OUT_PIN);
  servoIn.write(DOOR_CLOSE);
  servoOut.write(DOOR_CLOSE);

  digitalWrite(SS_PIN_1, HIGH);
  digitalWrite(SS_PIN_2, HIGH);

  // WiFi Setup
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  lcd.clear();
  lcd.print("Connecting WiFi");

  int count = 0;
  while (WiFi.status() != WL_CONNECTED && count < 20) {
    delay(500);
    Serial.print(".");
    count++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi Connected");
    lcd.clear();
    lcd.print("WiFi Connected");
  } else {
    Serial.println("\nNo WiFi");
    lcd.clear();
    lcd.print("No WiFi");
  }
  delay(1000);

  client.setInsecure();

  // SPI Initialization
  SPI.begin(18, 19, 23, 5);
  mfrc522_in.PCD_Init();
  mfrc522_out.PCD_Init();
  delay(100);

  Serial.println("System Ready!");
  displayIdleStatus();
}

void loop() {
  checkFireAlarm();

  if (!isEmergency) {
    checkReader(mfrc522_in, "IN");
    checkReader(mfrc522_out, "OUT");
    updateEnvironmentalControls(); // Check & print environmental status
  }
  
  delay(100);
}

// ---------------- ENVIRONMENTAL & RELAY CONTROL ----------------
int getPresentCount() {
  int count = 0;
  for (int i = 0; i < NUM_USERS; i++) {
    if (users[i].isInside) count++;
  }
  return count;
}

void updateEnvironmentalControls() {
  int occupants = getPresentCount();

  // Read Temperatures from both DHT sensors
  float temp1 = dht1.readTemperature();
  float temp2 = dht2.readTemperature();

  // Handle failed readings
  if (isnan(temp1)) temp1 = 0.0;
  if (isnan(temp2)) temp2 = 0.0;

  // Read Analog values from LDR sensors (0 to 4095)
  int ldr1 = analogRead(LDR_PIN_1);
  int ldr2 = analogRead(LDR_PIN_2);

  // Print values to Serial Monitor every 2 seconds
  if (millis() - lastSerialPrint >= 2000) {
    lastSerialPrint = millis();

    Serial.println("======================================");
    Serial.print("Occupants inside room: ");
    Serial.println(occupants);
    
    Serial.print("Temperature Sensor 1: ");
    Serial.print(temp1);
    Serial.println(" Â°C");

    Serial.print("Temperature Sensor 2: ");
    Serial.print(temp2);
    Serial.println(" Â°C");

    Serial.print("Light Sensor 1 Value : ");
    Serial.print(ldr1);
    Serial.println(ldr1 < LIGHT_THRESHOLD_LOW ? " (DARK)" : " (LIGHT)");

    Serial.print("Light Sensor 2 Value : ");
    Serial.print(ldr2);
    Serial.println(ldr2 < LIGHT_THRESHOLD_LOW ? " (DARK)" : " (LIGHT)");

    if (occupants == 0) {
      Serial.println("Status: Room Empty -> ALL PROCESSES OFF");
    } else {
      Serial.print("Fans Relay : ");
      Serial.println((temp1 >= TEMP_THRESHOLD_HIGH || temp2 >= TEMP_THRESHOLD_HIGH) ? "ON" : "OFF");

      Serial.print("LEDs Relay : ");
      Serial.println((ldr1 < LIGHT_THRESHOLD_LOW || ldr2 < LIGHT_THRESHOLD_LOW) ? "ON" : "OFF");
    }
    Serial.println("======================================\n");
  }

  // If no one is inside, shut down fans and LEDs immediately
  if (occupants == 0) {
    digitalWrite(RELAY_FANS_PIN, HIGH); // Relay OFF (Active LOW)
    digitalWrite(RELAY_LEDS_PIN, HIGH); // Relay OFF (Active LOW)
    return;
  }

  // Turn fans ON if EITHER sensor detects high temperature
  if (temp1 >= TEMP_THRESHOLD_HIGH || temp2 >= TEMP_THRESHOLD_HIGH) {
    digitalWrite(RELAY_FANS_PIN, LOW);  // Turn Relay ON
  } else {
    digitalWrite(RELAY_FANS_PIN, HIGH); // Turn Relay OFF
  }

  // Turn LEDs ON if ambient light is dark (value below threshold)
  if (ldr1 < LIGHT_THRESHOLD_LOW || ldr2 < LIGHT_THRESHOLD_LOW) {
    digitalWrite(RELAY_LEDS_PIN, LOW);  // Turn Relay ON
  } else {
    digitalWrite(RELAY_LEDS_PIN, HIGH); // Turn Relay OFF
  }
}

// ---------------- PARALLEL MQ-2 FIRE ALARM & AUTO-CLOSE ----------------
void checkFireAlarm() {
  int gasAnalog = analogRead(MQ2_PARALLEL_ANALOG_PIN);
  int gasDigital = digitalRead(MQ2_PARALLEL_DIGITAL_PIN);

  bool fireDetected = (gasAnalog > SMOKE_THRESHOLD || gasDigital == LOW);

  if (fireDetected) {
    if (!isEmergency) {
      isEmergency = true;
      Serial.println("ðŸ”¥ FIRE DETECTED! UNLOCKING ALL DOORS! ðŸ”¥");

      servoIn.write(DOOR_OPEN);
      servoOut.write(DOOR_OPEN);
      
      // Turn off fans during fire to prevent spreading smoke
      digitalWrite(RELAY_FANS_PIN, HIGH); 
    }

    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("!! FIRE ALARM !!");
    lcd.setCursor(0, 1);
    lcd.print("SMOKE DETECTED");

    tone(BUZZER, 2000); delay(200);
    tone(BUZZER, 1000); delay(200);
  } else {
    if (isEmergency) {
      noTone(BUZZER);
      Serial.println("Gas cleared. Starting 10-second door closing timer...");

      bool smokeReappeared = false;
      for (int i = 10; i > 0; i--) {
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("Gas Cleared!");
        lcd.setCursor(0, 1);
        lcd.print("Close in: ");
        lcd.print(i);
        lcd.print("s");

        tone(BUZZER, 800, 50); 

        unsigned long timerStart = millis();
        while (millis() - timerStart < 1000) {
          int gVal = analogRead(MQ2_PARALLEL_ANALOG_PIN);
          if (gVal > SMOKE_THRESHOLD || digitalRead(MQ2_PARALLEL_DIGITAL_PIN) == LOW) {
            smokeReappeared = true;
            break;
          }
          delay(50);
        }

        if (smokeReappeared) break;
      }

      if (!smokeReappeared) {
        isEmergency = false;
        servoIn.write(DOOR_CLOSE);
        servoOut.write(DOOR_CLOSE);

        lcd.clear();
        lcd.print("Area Safe!");
        lcd.setCursor(0, 1);
        lcd.print("Doors Closed.");
        delay(1500);

        Serial.println("Area safe. Doors locked.");
        displayIdleStatus();
      }
    }
  }
}

void displayIdleStatus() {
  int presentCount = getPresentCount();

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("Total: ");
  lcd.print(NUM_USERS);
  
  lcd.setCursor(0, 1);
  lcd.print("Present: ");
  lcd.print(presentCount);
}

void checkReader(MFRC522 &mfrc, String scanType) {
  if (!mfrc.PICC_IsNewCardPresent()) return;
  if (!mfrc.PICC_ReadCardSerial()) return;

  String uid = "";
  for (byte i = 0; i < mfrc.uid.size; i++) {
    if (mfrc.uid.uidByte[i] < 0x10) uid += "0";
    uid += String(mfrc.uid.uidByte[i], HEX);
    if (i != mfrc.uid.size - 1) uid += " ";
  }
  uid.toUpperCase();

  mfrc.PICC_HaltA();
  mfrc.PCD_StopCrypto1();

  digitalWrite(SS_PIN_1, HIGH);
  digitalWrite(SS_PIN_2, HIGH);

  Serial.println("----------------");
  Serial.print("Reader: "); Serial.println(scanType);
  Serial.print("UID: "); Serial.println(uid);

  int userIndex = -1;
  for (int i = 0; i < NUM_USERS; i++) {
    if (users[i].uid == uid) {
      userIndex = i;
      break;
    }
  }

  if (userIndex != -1) {
    if (scanType == "IN" && users[userIndex].isInside) {
      Serial.println("Already inside!");
      lcd.clear();
      lcd.print(users[userIndex].name);
      lcd.setCursor(0, 1);
      lcd.print("Already Inside!");
      triggerErrorBuzzer();
    } 
    else if (scanType == "OUT" && !users[userIndex].isInside) {
      Serial.println("Access Denied: Must Scan IN First");
      lcd.clear();
      lcd.print(users[userIndex].name);
      lcd.setCursor(0, 1);
      lcd.print("Scan IN First!");
      triggerErrorBuzzer();
    } 
    else {
      // Access Granted - Pass user's name to handleDoorOpening
      Serial.println("Access Granted (" + scanType + ")");
      tone(BUZZER, 1000); delay(200); noTone(BUZZER);

      bool entrySuccessful = handleDoorOpening(scanType, users[userIndex].name);

      // ONLY mark user state and send data if passage was detected
      if (entrySuccessful) {
        users[userIndex].isInside = (scanType == "IN");

        lcd.clear();
        lcd.print(users[userIndex].name + " [" + scanType + "]");
        lcd.setCursor(0, 1);
        lcd.print("Sending...");

        sendToGoogleSheets(users[userIndex].roll, users[userIndex].name, scanType);
      } else {
        Serial.println("Passage Timeout: User did NOT enter/exit.");
      }
    }
  } else {
    Serial.println("Unknown Card");
    lcd.clear();
    lcd.print("Unknown Card");
    triggerErrorBuzzer();
  }

  delay(1000);
  displayIdleStatus();
}

bool handleDoorOpening(String scanType, String userName) {
  Servo &targetServo = (scanType == "IN") ? servoIn : servoOut;
  int irPin = (scanType == "IN") ? IR_IN_PIN : IR_OUT_PIN;

  targetServo.write(DOOR_OPEN);
  lcd.clear();
  lcd.print("Door Opened");
  lcd.setCursor(0, 1);

  // Dynamic greeting based on scanType
  if (scanType == "OUT") {
    lcd.print("Goodbye " + userName);
  } else {
    lcd.print("Welcome " + userName);
  }

  unsigned long startTime = millis();
  bool passed = false;

  // 10-second window to cross IR sensor
  while (millis() - startTime < 10000) {
    checkFireAlarm(); 
    if (isEmergency) return false;

    if (digitalRead(irPin) == LOW) {
      passed = true;
      break;
    }
    delay(50);
  }

  if (passed) {
    lcd.clear();
    lcd.print("Passage Detected");
    lcd.setCursor(0, 1);
    lcd.print("Closing in 3s...");
    
    unsigned long delayStart = millis();
    while (millis() - delayStart < 3000) {
      checkFireAlarm();
      if (isEmergency) return false;
      delay(50);
    }
  }

  targetServo.write(DOOR_CLOSE);
  
  lcd.clear();
  if (passed) {
    lcd.print("Passage Done");
    lcd.setCursor(0, 1);
    lcd.print("Door Closed");
  } else {
    lcd.print("Timeout!");
    lcd.setCursor(0, 1);
    lcd.print("Door Auto Close");
  }
  delay(1000);

  return passed;
}

void triggerErrorBuzzer() {
  for (int i = 0; i < 3; i++) {
    tone(BUZZER, 1000); delay(150);
    noTone(BUZZER); delay(150);
  }
}

void sendToGoogleSheets(String roll, String name, String scanType) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi Disconnected!");
    lcd.clear();
    lcd.print("WiFi Disconn!");
    return;
  }

  HTTPClient https;
  String fullUrl = sheet_url + "?name=" + name + "&roll=" + roll + "&type=" + scanType;

  Serial.println("URL: " + fullUrl);

  if (https.begin(client, fullUrl)) {
    https.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
    https.setTimeout(15000); 

    int httpCode = https.GET();
    Serial.print("HTTP Code: "); Serial.println(httpCode);

    if (httpCode > 0) {
      lcd.clear();
      lcd.print(name + " [" + scanType + "]");
      lcd.setCursor(0, 1);
      lcd.print("Success!");
    } else {
      Serial.print("HTTP Error String: ");
      Serial.println(https.errorToString(httpCode));
      
      lcd.clear();
      lcd.print(name + " [" + scanType + "]");
      lcd.setCursor(0, 1);
      lcd.print("HTTP Err: " + String(httpCode));
    }
    https.end();
  } else {
    Serial.println("HTTPS begin failed");
    lcd.clear();
    lcd.print("Conn Init Fail");
  }
}
