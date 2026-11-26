import Foundation

// What the app itself says, per language (the same sentences as the React Native, Flutter and Android example_car_agent).

/// "Didn't catch that" for speech noise (English for the others).
let didNotCatchTexts = [
    "en": "Sorry, I didn't catch that. Could you say it again?",
    "pt-BR": "Desculpe, não entendi o que você disse. Pode repetir, por favor?",
    "pt-PT": "Desculpe, não percebi. Pode repetir?",
]

/// What the car demo says for a request this demo can't do (English for the others).
let notInDemoTexts = [
    "en": "This is not available in this demo, to make it available please contact info@davoice.io",
    "pt-BR": "Isso não está disponível nesta demonstração. Para disponibilizar, entre em contato com info@davoice.io",
    "pt-PT": "Isto não está disponível nesta demonstração. Para o disponibilizar, contacte info@davoice.io",
    "he": "זה לא זמין בהדגמה הזאת. כדי לקבל את זה, צרו איתנו קשר בכתובת info@davoice.io",
    "da": "Det er ikke tilgængeligt i denne demo. Kontakt info@davoice.io for at få det.",
    "sv": "Det är inte tillgängligt i den här demon. Kontakta info@davoice.io för att få det.",
    "el": "Αυτό δεν είναι διαθέσιμο σε αυτή την επίδειξη. Για να το αποκτήσετε, επικοινωνήστε με το info@davoice.io.",
]

/// A handed-over request when no remote model is set up (English for the others).
let noRemoteTexts = [
    "en": "I need to send this to a remote Model. To make this work, please setup a remote model in the App.",
    "pt-BR": "Preciso enviar isso para um modelo remoto. Para isso funcionar, configure um modelo remoto no aplicativo.",
    "pt-PT": "Preciso de enviar isto para um modelo remoto. Para isto funcionar, configure um modelo remoto na aplicação.",
    "he": "אני צריך לשלוח את זה למודל מרוחק. כדי שזה יעבוד, הגדירו מודל מרוחק באפליקציה.",
    "da": "Jeg skal sende det her til en ekstern model. Konfigurer en ekstern model i appen, så det virker.",
    "sv": "Jag behöver skicka det här till en fjärrmodell. Ställ in en fjärrmodell i appen så att det fungerar.",
    "el": "Πρέπει να το στείλω σε ένα απομακρυσμένο μοντέλο. Για να λειτουργήσει, ρυθμίστε ένα απομακρυσμένο μοντέλο στην εφαρμογή.",
]

/// Local confidence held a command back and no remote agent is set up.
let lowConfidenceTexts = [
    "en": "For this command I need a remote agent.",
    "pt-BR": "Para esse comando eu preciso de um agente remoto.",
]

/// General questions ("who is the president", "tell me a joke"): no remote assistant in this demo.
let generalQuestionsMessage = [
    "en": "General questions go to a remote assistant, which isn't set up in this demo. I can help you with the car.",
    "pt-BR": "Perguntas gerais vão para um assistente remoto, que não está configurado nesta demonstração. Posso te ajudar com o carro.",
]
