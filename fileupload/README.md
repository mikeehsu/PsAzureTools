# PsAzureTools > FileUpload
This code in intended to be deployed into a storage account allowing any person with the link to the Static Website and a SAS token to be able to upload a document into it using a friendly web page.

To deploy, use the following steps:
* create (or use an existing) a storage account
* on the storage account, enable Resource Sharing (CORS)
    * set Allow orgins to *
    * set Allowed methods to POST, PUT
    * set Allowed headers to *
    * set Exposed headers to *
* on the storage account, enable Static website and set "Index document name" to index.html
* copy index.html and main.js to the root folder of the $web container
* create a container named "documents" to store uploaded files. (You can use a different container name, but must adjust the URL provided for uploading.)

To provide a link for uploading a file:
* create a SAS token granting the "Create" permission on the container
* copy the Primary Endpoint for the Static website, attaching the SAS token on the end of the URL
* if "documents" is not the container name, append the "&container=\<containerName\>" onto the URL

To upload a file:
* navigate to URL described above
* click on "Choose File"
* select a file to upload. The files will be upload with a randomized string attached to the end of the file, to avoid any conflicting filenames, if multiple files are uploaded.

To build:
* check out the code
* install the required modules using: npm install
* build the project using: npm run build
* this will create a new main.js into the ./dist directory


