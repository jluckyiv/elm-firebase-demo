var functions = require('firebase-functions');

const admin = require('firebase-admin');
admin.initializeApp(functions.config().firebase);

// // Create and Deploy Your First Cloud Functions
// // https://firebase.google.com/docs/functions/write-firebase-functions
//
// exports.helloWorld = functions.https.onRequest((request, response) => {
//  response.send("Hello from Firebase!");
// });

exports.sendNotification = functions.database.ref('/{userId}/presents/{presentId}')
    .onWrite(event => {
        var topic = "presents";
        // Grab the current value of what was written to the Realtime Database.
        var eventSnapshot = event.data;
        let present = eventSnapshot.child("description").val();

        return event.data.ref.parent.parent.child('meta/name').once("value")
            .then(snapshot => {
                let person = snapshot.val();
                // console.log(`* ${person} added ${present}`);

                var payload = {
                    data: {
                        person: person,
                        present: present
                    }
                };
                return admin.messaging().sendToTopic(topic, payload);
            })
            .then(function(response) {
                // Send a message to devices subscribed to the provided topic.
                // See the MessagingTopicResponse reference documentation for the
                // contents of response.
                console.log("Successfully sent message:", response);
            })
            .catch(function(error) {
                console.error("Error sending message:", error);
            });
    });