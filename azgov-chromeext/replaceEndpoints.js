//$(document).ready(function() {

document.addEventListener('DOMContentLoaded', function() {
    nodes = document.querySelectorAll('*');
    for(var i=0; i<55; i++) {
        nodes[i].innerHTML = nodes[i].innerHTML.replaceAll("portal.azure.com","portal.azure.us")
            .replaceAll("login.microsoftonline.com","login.microsoftonline.us")
            .replaceAll("//management.azure.com","//management.usgovcloudapi.net");
    }
});

