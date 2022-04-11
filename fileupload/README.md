# PsAzureTools > FileUpload
This code in intended to be deployed into a storage account allowing any person with the link to the Static Website and a SAS token to be able to upload a document into it using a friendly web page.

The use this take the following steps:

* check out the code
* install the required modules using: npm install
* build the project using: npm run build
* create (or use) a storage account
* enable Resource sharing (CORS)
    * set Allow orgins to *
    * set Allowed methods to POST, PUT
    * set Allowed headers to *
    * set Exposed headers to *
* enable Static website, set Index document name to index.html
* copy index.html and ./dist/main.js to the root folder of $web
* create a "documents" container (or a container for the uploaded files)

To provide a link for uploading a file:
* create a SAS token granting the "Create" permission on the container
* copy the Primary Endpoint for the Static website, attaching the SAS token on the end of the URL
* if "documents" is not your container name, append the "&container=\<containerName\>" on to the URL

To upload a file:
* navigate to URL described above
* click on "Choose File"
* select a file to upload

The file will be upload with a randomized string attached to the end of the file, to avoid any conflicting filenames.

