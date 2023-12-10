!/bin/ksh

RUNDIR=~/run/rdb; cd $RUNDIR
BUCKET=glmck13-textract
FORMAT=png
TMPOCR=receipt.$FORMAT
TMPJSON=receipt.json
TMPDB=receipt.db
TMPCSV=receipt.csv
PURCHASES=Purchases.db
rm -f $TMPOCR $TMPJSON $TMPCSV $TMPDB

list=$(sqlite3 $PURCHASES 'SELECT DISTINCT Vendor from Purchases')
echo "Current vendors:"
if [ "$list" ]; then
	n=1; for v in $list
	do
		echo -e "\t$n) $v"
		let n=$n+1
	done
else
	echo -e "\t** None **"
fi
typeset -u VENDOR
while [ ! "$VENDOR" ]
do
	echo -n "Enter vendor # or name: "; read x
	if [[ $x == +([0-9]) ]]; then
		n=1; for v in $list
		do
			if [ "$x" -eq "$n" ]; then
				VENDOR=$v
				break
			fi
			let n=$n+1
		done
	else
		VENDOR=$x
	fi
done
echo -e "Vendor is: \"$VENDOR\"\n"

echo -n "Feed receipt into scanner, then hit enter: "; read x
echo -n "Scanning... "
scanimage -d dsseries --format=$FORMAT --resolution=600 >$TMPOCR
echo -e "Complete!\n"

echo "Copying receipt to AWS bucket... "
aws s3 rm s3://$BUCKET/$TMPOCR
aws s3 cp $TMPOCR s3://$BUCKET
echo -e "Complete!\n"

echo "Running textract... "
arg=$(cat - <<EOF
{"S3Object": {"Bucket": "$BUCKET", "Name": "$TMPOCR"}}
EOF
)
aws textract analyze-expense --document "$arg" >$TMPJSON
aws s3 rm s3://$BUCKET/$TMPOCR
echo -e "Complete!\n"

ID=$(sqlite3 $PURCHASES 'SELECT COUNT(Id) from Purchases')

python3 <<EOF >$TMPCSV
import sys
import json

Tally = []
Id = $ID
Vendor = "$VENDOR"
Address = ""
Date = ""
Item = ""
Price = ""
print("Id,Vendor,Address,Date,Item,Price")

receipt = json.loads(open("$TMPJSON").read())

for x in receipt["ExpenseDocuments"][0]["SummaryFields"]:
	if x["Type"]["Text"] == "ADDRESS":
		Address = x["ValueDetection"]["Text"]
		Address = Address.replace('\n', ',')
	elif x["Type"]["Text"] == "INVOICE_RECEIPT_DATE":
		Date = x["ValueDetection"]["Text"]

for x in receipt["ExpenseDocuments"][0]["LineItemGroups"][0]["LineItems"]:
	for y in x["LineItemExpenseFields"]:
		if y["Type"]["Text"] == "EXPENSE_ROW":
			Item = y["ValueDetection"]["Text"]
		elif y["Type"]["Text"] == "PRICE":
			Price = y["ValueDetection"]["Text"]

	Item = Item.split('\n').pop()

	Id += 1
	entry = [str(Id), '"'+Vendor+'"', '"'+Address+'"', '"'+Date+'"', '"'+Item+'"', Price]

	Tally.append(entry)

for entry in Tally:
	print(','.join(entry))
EOF

sqlite3 $TMPDB <<EOF
.import $TMPCSV Purchases --csv
EOF

echo -n "Please clean the extracted purchase items as needed. Hit enter to proceed: "; read x
sqlitebrowser $TMPDB
echo -e "Complete!\n"

echo -n "Import receipt into main database (Y/n)? "; read x
if [ "$x" -a "$x" != "Y" ]; then
	echo "Aborted!"
else
	sqlite3 -cmd ".dump" $TMPDB </dev/null | sqlite3 $PURCHASES
	echo "Complete! To analyze, open: http://localhost:3000"
fi
