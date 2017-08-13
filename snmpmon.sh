#!/usr/bin/env bash

# простые системы мониторинга самые эффективные (иногда), концепция одна строчка - один сервер была подсмотрена у яндекса
# только у них была веб-морда, а тут консольный вывод, который можно распарсить или сохранить в файл и отправить себе на почту или обернуть в watch для риалтайма
# столбцы: имя, адрес, аптайм, память, % используемой памяти, количество ядер CPU, % использования всех CPU и диски - имя, объем и процент использования каждого тома
# значения, превышающие пороговые подсвечиваются желтым и красным, слишком слабое потребление ресурсов - зеленым, недоступные хосты - хорошо заметные пустые строки 
# скрипт из коробки работает с linux, windows и ESXi в конфиг файле надо через пробел указать snmp комьюнити на чтение и доменное имя хоста: одна строчка - один сервер

# константы:
maxCores="32"		 # максимальное количество ядер у наблюдаемых серверов
configFile="snmpmon.cfg" # имя конфигурационного файла
red="\033[31;1;31m"	 # далее определяем последовательности для цветов в bash
yellow="\033[31;1;33m"
green="\033[31;1;32m"
endcolor="\033[0m"	 # возвращаемся к нормальному цвету

# выводим шапку на экран
echo -e "Server name\t\t\tIP\t\tUptime\t\tRAM\tuseRAM\tcores\tCPU%\tDisk usage"

# пустые строки и строки начинающиеся с решетки пропускаем и начинаем цикл по строкам
sed -e /^#/d -e /^$/d $configFile | while read line
do
    # парсим строки
    set -- $line
    com=$1  # комьюнити
    host=$2 # имя хоста

    # проверяем доступность хоста по snmp:
    if $(snmpbulkget -v 2c -c $com -r 1 -t 1 $host &> /dev/null)
    then
	# узнаем объем оперативной памяти
	allMem=$(snmpget -v 2c -c $com -OUvq $host hrMemorySize.0)
	# подсчитываем количество запущенных процессов
	countProc=$(snmpget -v 2c -c $com -OUvq $host hrSystemProcesses.0)
	# суммируем память потребляемую всеми процессами
	memUse=$(snmpbulkget -v 2c -Cr$countProc -c $com -OUvq $host hrSWRunPerfMem | awk '{m=m+$1} END{print(m)}')
	# рассчитываем процент использованной памяти
	let "memUseProcent = memUse * 100 / allMem"
        # выражаем всю память в гигабайтах
	# если делить на 1024 - из-за округления будет получаться 1 гб там, где на самом деле их 2
        # TODO: доработать преобразование, т.к. в нынешнем варианте вместо 128 Гб показывает 134...
	let "allMemHum = allMem / 1000 / 1000"

	# вычисляем количество ядер, а чтобы оптимизировать bulk запрос считаем, что максимум у хоста может быть 32 ядра - константу можно поправить в начале файле
	rawProc=$(snmpbulkget -v 2c -Cr$maxCores -c $com -OUq $host hrProcessorLoad)
	countProc=$(echo "$rawProc" | grep hrProcessorLoad | wc -l)
	# вычисляем суммарную загрузку всех найденных ядер
	sumProc=$(echo "$rawProc" | head -n $countProc | awk '{c=c+$2} END{print(c)}')
	# рассчитываем загрузку всех процессоров в среднем
        # если все ядра загружены на ноль, проверяем это отдельно
	if [ $countProc -eq 0 ]; then
            averProc="0"
        else
            let "averProc = sumProc / countProc"
        fi

	# получаем аптайм и айпи хоста
	uptime=$(snmpget -v 2c -c $com -OUvq $host system.sysUpTime.0)
        # этот вариант не работает, если имя прописано в /etc/hosts
        # ip=$(host $host | awk '{print $4}')
        ip=$(ping $host -c 1 -n | grep "bytes from" | awk '{print $4}')
        ip=${ip:0:-1}

	# т.к. мы пишем на баше, то у нас нет нормальных областей видимости для переменных
	# мы сейчас уже внутри цикла и чтобы передавать изменяющиеся данные во вложенный цикл используем пайп
        mkfifo pipe # это будет временный файлик пайп в папке со скриптом
	disk="" # переменная, которую будет модифицировать вложенный цикл
	# snmp дает разные описания для томов в разных системах, поэтому определяем тип ОС
	osType=$(snmpget -v 2c -c $com $host sysDescr.0)
	
	# получаем описания ключевых томов - всех букв дисков для винды, корня и домашней директории для линукса, специфических томов для ESXi
	# к сожалению, тот могут быть необходимы правки под наблюдаемые системы...
	# инфу сохраняем в пайп. Еще один важный момент - скрипт зависнет, если не отгрепакется вывод булкгета!
	if $(echo $osType | grep Windows &> /dev/null); then
	    snmpbulkget -v 2c -c $com $host hrStorageDescr | grep "Serial Number" > pipe &
	elif $(echo $osType | grep inux &> /dev/null); then
	    snmpbulkget -v 2c -c $com -Cr20 $host hrStorageDescr | grep "/$\|/boot" > pipe &
	elif $(echo $osType | grep ESXi &> /dev/null); then
	    snmpbulkget -v 2c -c $com $host hrStorageDescr | grep "r.6\|r.5" > pipe &
	fi

	# читаем из пайпа (см. ниже: done < pipe)
	while read line
        do
            # парсим вывод snmp запроса, полученного выше 
	    set -- $line
	    # айди тома в snmp - это последняя цифра после точки, она нужна для подстановки в другие snmp запросы
	    id=${1:$(expr index "$1" '.')}
            # имя тома обрезанное до 3 символов
	    tom=${4:0:3}
	    #label=${5:6:6}

	    # узнаем количество кластеров, количество используемых кластеров и размер кластера
	    clusterCount=$(snmpget -v 2c -c $com -OUvq $host hrStorageSize.$id)
	    clusterUsed=$(snmpget -v 2c -c $com -OUvq $host hrStorageUsed.$id)
	    clusterSize=$(snmpget -v 2c -c $com -OUvq $host hrStorageAllocationUnits.$id)
	    
	    # рассчитываем размер тома в гигабайтах
	    let "size = clusterCount * clusterSize / 1024 / 1024 / 1024"
	    # рассчитываем сколько места использовано - в итоге это слишком засоряло вывод и я отключил эту опцию
	    #let "used = clusterUsed * clusterSize / 1000 / 1000 / 1000"
	    # рассчитываем процент использования тома
	    let "prUse = clusterUsed * 100 / clusterCount"

	    # определяем пороговые значения для подсветки значений цветом
	    if [ "$prUse" -ge "90" ]; then
		prUse="$red"$prUse"$endcolor"
	    elif [ "$prUse" -ge "75" ]; then
		prUse="$yellow"$prUse"$endcolor"
	    elif [ "$prUse" -le "25" ]; then
		prUse="$green"$prUse"$endcolor"
	    fi

	    # если размер тома двухзначное число - добавляем в начало пробел, чтобы красиво выравнять вывод на экран
	    if [ ${#size} -eq 2 ]; then
		size=" "$size
	    fi
	    
	    # формируем вывод на экран, конкатенируя его с самим собой - инициализация перемнной для первой конкатенации была перед циклом
	    disk=$disk$(echo -e $tom" ("$size")Gb "$prUse%)"\t "

	done < pipe
	rm pipe # удаляем временный файл
	# внимание, если запускать через watch, то завершение через ^С может прийтись на момент существования файла и его придется удалять вручную

	# подсвечиваем цветом пороговые значения для памяти
	if [ "$memUseProcent" -ge "90" ]; then
	    memUseProcent="$red"$memUseProcent"$endcolor"
	elif [ "$memUseProcent" -ge "75" ]; then
	    memUseProcent="$yellow"$memUseProcent"$endcolor"
	elif [ "$memUseProcent" -le "25" ]; then
	    memUseProcent="$green"$memUseProcent"$endcolor"
	fi

	# и для загрузки процессора
	if [ "$averProc" -ge "90" ]; then
	    averProc="$red"$averProc"$endcolor"
	elif [ "$averProc" -ge "75" ]; then
	    averProc="$yellow"$averProc"$endcolor"
	elif [ "$averProc" -le "10" ]; then
	    averProc="$green"$averProc"$endcolor"
	fi

    else
	# если хост недоступен, заполняем пробелами все поля и делаем строку красной
	memUseProcent="--"
	averProc="-"
	allMemHum="-"
	uptime="-:--:--:--:--"
	ip="---.---.---.---"
	disk="C: --"
	countProc="-"
	host="$red"$host"$endcolor"
    fi

    # выводим на экран значения под шапкой построчно
    echo -e $host"\t"$ip"\t"$uptime"\t"$allMemHum" Gb\t"$memUseProcent"%\t"$countProc"\t"$averProc"%\t"$disk | column -s '\t'
   
done


